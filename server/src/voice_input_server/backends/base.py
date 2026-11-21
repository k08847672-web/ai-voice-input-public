from __future__ import annotations

from typing import Protocol

from voice_input_server.protocol import StartConfiguration


class RecognitionSession(Protocol):
    async def start(self) -> None:
        """Connect and validate the upstream before accepting audio."""

    async def feed(self, audio: bytes) -> str | None:
        """Consume PCM bytes and optionally return a complete partial transcript."""

    async def finish(self) -> str:
        """Return the final transcript after all audio has been consumed."""

    async def close(self) -> None:
        """Release resources without producing a final transcript."""


class BackendFactory(Protocol):
    def create(self, config: StartConfiguration) -> RecognitionSession:
        """Create one isolated recognition session."""
