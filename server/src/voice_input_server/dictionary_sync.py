from __future__ import annotations

import asyncio
import os
import secrets
import stat
import tempfile
from pathlib import Path

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from pydantic import BaseModel, Field, field_validator

MAGIC = b"VOICEINPUT-DICTIONARY-V1\n"
MAX_FILE_BYTES = 1_200_000


class DictionarySnapshot(BaseModel):
    revision: int = Field(ge=0)
    entries: dict[str, str] = Field(max_length=1000)

    @field_validator("entries")
    @classmethod
    def validate_entries(cls, entries: dict[str, str]) -> dict[str, str]:
        if any(
            not spoken.strip()
            or spoken != spoken.strip()
            or len(spoken) > 100
            or "=" in spoken
            or any(character in spoken for character in "\n\r\u2028\u2029")
            or not written.strip()
            or len(written) > 200
            or any(character in written for character in "\n\r\u2028\u2029")
            for spoken, written in entries.items()
        ):
            raise ValueError("invalid dictionary entry")
        return entries


class DictionaryStorageError(Exception):
    pass


class DictionaryStore:
    """Single-process, owner-only encrypted snapshot with atomic revision checks."""

    def __init__(self, directory: Path) -> None:
        if directory.is_symlink() or not directory.is_dir():
            raise DictionaryStorageError("dictionary directory is invalid")
        if stat.S_IMODE(directory.stat().st_mode) & 0o077:
            raise DictionaryStorageError("dictionary directory must be owner-only")
        self.path = directory / "dictionary.sync.enc"
        key_path = directory / "dictionary.sync.key"
        if self.path.exists() and not key_path.exists():
            raise DictionaryStorageError("dictionary encryption key is missing")
        key = self._load_or_create_key(key_path)
        self._cipher = AESGCM(key)
        self._lock = asyncio.Lock()
        self._snapshot = self._load()

    @staticmethod
    def _load_or_create_key(path: Path) -> bytes:
        if path.is_symlink():
            raise DictionaryStorageError("dictionary key must not be a symlink")
        if not path.exists():
            key = secrets.token_bytes(32)
            try:
                descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            except FileExistsError:
                pass
            else:
                with os.fdopen(descriptor, "wb") as output:
                    output.write(key)
                    output.flush()
                    os.fsync(output.fileno())
        if stat.S_IMODE(path.stat().st_mode) & 0o077:
            raise DictionaryStorageError("dictionary key must be owner-only")
        key = path.read_bytes()
        if len(key) != 32:
            raise DictionaryStorageError("dictionary key is invalid")
        return key

    def _load(self) -> DictionarySnapshot:
        if not self.path.exists():
            return DictionarySnapshot(revision=0, entries={})
        if self.path.is_symlink() or stat.S_IMODE(self.path.stat().st_mode) & 0o077:
            raise DictionaryStorageError("dictionary file must be owner-only")
        encrypted = self.path.read_bytes()
        if not encrypted.startswith(MAGIC) or len(encrypted) > MAX_FILE_BYTES:
            raise DictionaryStorageError("dictionary file is invalid")
        try:
            plaintext = self._cipher.decrypt(
                encrypted[len(MAGIC) : len(MAGIC) + 12],
                encrypted[len(MAGIC) + 12 :],
                MAGIC,
            )
            return DictionarySnapshot.model_validate_json(plaintext)
        except (InvalidTag, ValueError, UnicodeError) as exc:
            raise DictionaryStorageError("dictionary file cannot be decrypted") from exc

    async def read(self) -> DictionarySnapshot:
        async with self._lock:
            return self._snapshot.model_copy(deep=True)

    async def replace(
        self, expected_revision: int, entries: dict[str, str]
    ) -> DictionarySnapshot | None:
        async with self._lock:
            if self._snapshot.revision != expected_revision:
                return None
            if self._snapshot.entries == entries:
                return self._snapshot.model_copy(deep=True)
            snapshot = DictionarySnapshot(revision=expected_revision + 1, entries=entries)
            plaintext = snapshot.model_dump_json().encode("utf-8")
            nonce = secrets.token_bytes(12)
            encrypted = MAGIC + nonce + self._cipher.encrypt(nonce, plaintext, MAGIC)
            if len(encrypted) > MAX_FILE_BYTES:
                raise DictionaryStorageError("dictionary file exceeds size limit")
            descriptor, temporary = tempfile.mkstemp(
                prefix=".dictionary-sync-", dir=self.path.parent
            )
            try:
                with os.fdopen(descriptor, "wb") as output:
                    output.write(encrypted)
                    output.flush()
                    os.fsync(output.fileno())
                os.replace(temporary, self.path)
                directory_fd = os.open(self.path.parent, os.O_RDONLY)
                try:
                    os.fsync(directory_fd)
                finally:
                    os.close(directory_fd)
            finally:
                try:
                    os.unlink(temporary)
                except FileNotFoundError:
                    pass
            self._snapshot = snapshot
            return snapshot.model_copy(deep=True)
