from __future__ import annotations

from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, field_validator

MAX_TRANSCRIPT_CHARS = 100_000
MAX_ERROR_MESSAGE_CHARS = 1_000


class StartConfiguration(BaseModel):
    model_config = ConfigDict(extra="forbid")

    sample_rate: Literal[16000]
    channels: Literal[1]
    encoding: Literal["pcm_s16le"]
    language: str = Field(min_length=2, max_length=32)
    mode: Literal["faithful", "smart", "command"]
    hotwords: list[str] = Field(default_factory=list, max_length=500)
    dictionary: dict[str, str] = Field(default_factory=dict)
    style: str = Field(default="", max_length=2000)
    source_application: str | None = Field(default=None, max_length=255)

    @field_validator("hotwords")
    @classmethod
    def validate_hotwords(cls, values: list[str]) -> list[str]:
        if any(not value.strip() or len(value) > 100 for value in values):
            raise ValueError("hotwords must be non-empty and at most 100 characters")
        return values

    @field_validator("dictionary")
    @classmethod
    def validate_dictionary(cls, value: dict[str, str]) -> dict[str, str]:
        if len(value) > 1000:
            raise ValueError("dictionary has too many entries")
        invalid = any(
            not key or len(key) > 100 or len(replacement) > 200
            for key, replacement in value.items()
        )
        if invalid:
            raise ValueError("invalid dictionary entry")
        return value


class StartMessage(BaseModel):
    model_config = ConfigDict(extra="forbid")

    type: Literal["start"]
    session_id: UUID
    protocol_version: Literal[1]
    config: StartConfiguration


class StopMessage(BaseModel):
    model_config = ConfigDict(extra="forbid")

    type: Literal["stop"]
    session_id: UUID


class ServerMessage(BaseModel):
    model_config = ConfigDict(extra="forbid")

    type: Literal["ready", "partial", "final", "error"]
    session_id: UUID | None = None
    text: str | None = Field(default=None, max_length=MAX_TRANSCRIPT_CHARS)
    code: str | None = Field(default=None, pattern=r"^[a-z0-9_]{1,64}$")
    message: str | None = Field(default=None, min_length=1, max_length=MAX_ERROR_MESSAGE_CHARS)

    def wire(self) -> dict[str, object]:
        return self.model_dump(mode="json", exclude_none=True)


def ready(session_id: UUID) -> ServerMessage:
    return ServerMessage(type="ready", session_id=session_id)


def partial(session_id: UUID, text: str) -> ServerMessage:
    return ServerMessage(type="partial", session_id=session_id, text=text)


def final(session_id: UUID, text: str) -> ServerMessage:
    return ServerMessage(type="final", session_id=session_id, text=text)


def error(session_id: UUID | None, code: str, message: str) -> ServerMessage:
    return ServerMessage(type="error", session_id=session_id, code=code, message=message)
