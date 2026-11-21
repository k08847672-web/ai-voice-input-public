from __future__ import annotations

from dataclasses import dataclass

from voice_input_server.protocol import StartConfiguration


@dataclass(slots=True)
class MockRecognitionSession:
    transcript: str
    bytes_received: int = 0
    last_partial_length: int = 0

    async def start(self) -> None:
        return None

    async def feed(self, audio: bytes) -> str | None:
        self.bytes_received += len(audio)
        # PCM16 at 16 kHz is 32,000 bytes/s. Reveal more text every 250 ms.
        reveal_steps = self.bytes_received // 8_000
        target_length = min(
            len(self.transcript),
            int(reveal_steps * max(1, len(self.transcript) / 8)),
        )
        if target_length <= self.last_partial_length:
            return None
        self.last_partial_length = target_length
        return self.transcript[:target_length]

    async def finish(self) -> str:
        return self.transcript

    async def close(self) -> None:
        return None


@dataclass(frozen=True, slots=True)
class MockBackendFactory:
    transcript: str

    def create(self, config: StartConfiguration) -> MockRecognitionSession:
        del config
        return MockRecognitionSession(self.transcript)
