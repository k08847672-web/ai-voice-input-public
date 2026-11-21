from __future__ import annotations

import io
import wave
from dataclasses import dataclass, field

import httpx

from voice_input_server.organizer import TextOrganizer
from voice_input_server.protocol import StartConfiguration


@dataclass(slots=True)
class OpenAIHTTPRecognitionSession:
    config: StartConfiguration
    url: str
    token: str
    model: str
    timeout_seconds: int
    organizer: TextOrganizer | None
    audio: bytearray = field(default_factory=bytearray)

    async def start(self) -> None:
        return None

    async def feed(self, audio: bytes) -> str | None:
        self.audio.extend(audio)
        return None

    async def finish(self) -> str:
        wav_data = self._wav_data()
        headers = {"Authorization": f"Bearer {self.token}"} if self.token else {}
        form = {"model": self.model, "response_format": "json"}
        if self.config.language != "auto":
            form["language"] = self.config.language.split("-", maxsplit=1)[0]
        async with httpx.AsyncClient(timeout=self.timeout_seconds) as client:
            response = await client.post(
                self.url,
                headers=headers,
                data=form,
                files={"file": ("speech.wav", wav_data, "audio/wav")},
            )
            response.raise_for_status()
        payload = response.json()
        text = payload.get("text")
        if not isinstance(text, str):
            raise ValueError("upstream response has no text field")
        if self.organizer is not None:
            return await self.organizer.organize(text, self.config)
        return text

    async def close(self) -> None:
        self.audio.clear()

    def _wav_data(self) -> bytes:
        output = io.BytesIO()
        with wave.open(output, "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(16_000)
            wav.writeframes(self.audio)
        return output.getvalue()


@dataclass(frozen=True, slots=True)
class OpenAIHTTPBackendFactory:
    url: str
    token: str
    model: str
    timeout_seconds: int
    organizer: TextOrganizer | None = None

    def create(self, config: StartConfiguration) -> OpenAIHTTPRecognitionSession:
        return OpenAIHTTPRecognitionSession(
            config=config,
            url=self.url,
            token=self.token,
            model=self.model,
            timeout_seconds=self.timeout_seconds,
            organizer=self.organizer,
        )
