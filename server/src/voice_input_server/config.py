from __future__ import annotations

import ipaddress
import os
import re
from dataclasses import dataclass
from urllib.parse import urlsplit


def _positive_int(name: str, default: int) -> int:
    value = int(os.getenv(name, str(default)))
    if value <= 0:
        raise ValueError(f"{name} must be positive")
    return value


@dataclass(frozen=True, slots=True)
class Settings:
    environment: str
    bearer_token: str
    backend: str
    mock_transcript: str
    max_audio_bytes: int
    max_session_seconds: int
    max_concurrent_sessions: int
    shutdown_grace_seconds: int
    backend_close_timeout_seconds: int
    openai_url: str
    openai_token: str
    openai_model: str
    openai_timeout_seconds: int
    voiceink_url: str
    voiceink_token: str
    voiceink_timeout_seconds: int
    organizer_url: str
    organizer_token: str
    organizer_model: str
    organizer_timeout_seconds: int
    organizer_tls_server_name: str = ""
    dictionary_sync_dir: str = ""
    friend_bearer_token: str = ""

    @classmethod
    def from_env(cls) -> Settings:
        settings = cls(
            environment=os.getenv("VOICE_INPUT_ENV", "development").lower(),
            bearer_token=os.getenv("VOICE_INPUT_BEARER_TOKEN", ""),
            friend_bearer_token=os.getenv("VOICE_INPUT_FRIEND_BEARER_TOKEN", ""),
            backend=os.getenv("VOICE_INPUT_BACKEND", "mock").lower(),
            mock_transcript=os.getenv("VOICE_INPUT_MOCK_TRANSCRIPT", "语音输入法连接成功。"),
            max_audio_bytes=_positive_int("VOICE_INPUT_MAX_AUDIO_BYTES", 64 * 1024 * 1024),
            max_session_seconds=_positive_int("VOICE_INPUT_MAX_SESSION_SECONDS", 180),
            max_concurrent_sessions=_positive_int("VOICE_INPUT_MAX_CONCURRENT_SESSIONS", 4),
            shutdown_grace_seconds=_positive_int("VOICE_INPUT_SHUTDOWN_GRACE_SECONDS", 20),
            backend_close_timeout_seconds=_positive_int(
                "VOICE_INPUT_BACKEND_CLOSE_TIMEOUT_SECONDS", 5
            ),
            openai_url=os.getenv("VOICE_INPUT_OPENAI_URL", ""),
            openai_token=os.getenv("VOICE_INPUT_OPENAI_TOKEN", ""),
            openai_model=os.getenv("VOICE_INPUT_OPENAI_MODEL", "whisper-1"),
            openai_timeout_seconds=_positive_int("VOICE_INPUT_OPENAI_TIMEOUT_SECONDS", 90),
            voiceink_url=os.getenv("VOICE_INPUT_VOICEINK_URL", ""),
            voiceink_token=os.getenv("VOICE_INPUT_VOICEINK_TOKEN", ""),
            voiceink_timeout_seconds=_positive_int("VOICE_INPUT_VOICEINK_TIMEOUT_SECONDS", 30),
            organizer_url=os.getenv("VOICE_INPUT_ORGANIZER_URL", ""),
            organizer_token=os.getenv("VOICE_INPUT_ORGANIZER_TOKEN", ""),
            organizer_model=os.getenv("VOICE_INPUT_ORGANIZER_MODEL", ""),
            organizer_timeout_seconds=_positive_int("VOICE_INPUT_ORGANIZER_TIMEOUT_SECONDS", 30),
            organizer_tls_server_name=os.getenv("VOICE_INPUT_ORGANIZER_TLS_SERVER_NAME", ""),
            dictionary_sync_dir=os.getenv(
                "VOICE_INPUT_DICTIONARY_SYNC_DIR", os.getenv("VOICE_INPUT_INSTALL_ROOT", "")
            ),
        )
        settings.validate()
        return settings

    def validate(self) -> None:
        if self.dictionary_sync_dir and not os.path.isabs(self.dictionary_sync_dir):
            raise ValueError("VOICE_INPUT_DICTIONARY_SYNC_DIR must be absolute")
        if self.environment == "production" and not self.bearer_token:
            raise ValueError("VOICE_INPUT_BEARER_TOKEN is required in production")
        if self.friend_bearer_token and self.friend_bearer_token == self.bearer_token:
            raise ValueError("VOICE_INPUT_FRIEND_BEARER_TOKEN must differ from the private token")
        if self.backend not in {"mock", "openai-http", "voiceink-websocket"}:
            raise ValueError(
                "VOICE_INPUT_BACKEND must be mock, openai-http, or voiceink-websocket"
            )
        if self.backend == "openai-http" and not self.openai_url:
            raise ValueError("VOICE_INPUT_OPENAI_URL is required for openai-http")
        if self.backend == "openai-http":
            self._validate_http_url("VOICE_INPUT_OPENAI_URL", self.openai_url)
        if self.backend == "voiceink-websocket" and not self.voiceink_url:
            raise ValueError("VOICE_INPUT_VOICEINK_URL is required for voiceink-websocket")
        if self.backend == "voiceink-websocket":
            self._validate_websocket_url("VOICE_INPUT_VOICEINK_URL", self.voiceink_url)
        if bool(self.organizer_url) != bool(self.organizer_model):
            raise ValueError(
                "VOICE_INPUT_ORGANIZER_URL and VOICE_INPUT_ORGANIZER_MODEL must be set together"
            )
        if self.organizer_url:
            self._validate_http_url("VOICE_INPUT_ORGANIZER_URL", self.organizer_url)
        if self.organizer_tls_server_name:
            parsed = urlsplit(self.organizer_url)
            try:
                ipaddress.ip_address(parsed.hostname or "")
            except ValueError as exc:
                raise ValueError(
                    "organizer TLS server name requires an IP-address HTTPS URL"
                ) from exc
            if parsed.scheme != "https" or not re.fullmatch(
                r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", self.organizer_tls_server_name
            ):
                raise ValueError("invalid VOICE_INPUT_ORGANIZER_TLS_SERVER_NAME")

    @staticmethod
    def _validate_http_url(name: str, value: str) -> None:
        parsed = urlsplit(value)
        if (
            parsed.scheme not in {"http", "https"}
            or not parsed.hostname
            or parsed.username
            or parsed.password
            or parsed.query
            or parsed.fragment
        ):
            raise ValueError(f"{name} must be an HTTP URL without credentials")

    @staticmethod
    def _validate_websocket_url(name: str, value: str) -> None:
        parsed = urlsplit(value)
        if (
            parsed.scheme not in {"ws", "wss"}
            or not parsed.hostname
            or parsed.username
            or parsed.password
            or parsed.query
            or parsed.fragment
        ):
            raise ValueError(f"{name} must be a WebSocket URL without credentials")
