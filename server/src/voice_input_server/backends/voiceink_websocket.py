from __future__ import annotations

import asyncio
import json
from contextlib import suppress
from dataclasses import dataclass, field
from typing import cast
from uuid import uuid4

from websockets.asyncio.client import ClientConnection, connect
from websockets.exceptions import ConnectionClosed

from voice_input_server.organizer import TextOrganizer
from voice_input_server.protocol import MAX_TRANSCRIPT_CHARS, StartConfiguration


class VoiceInkUpstreamError(Exception):
    pass


@dataclass(slots=True)
class VoiceInkWebSocketRecognitionSession:
    # A sleeping/reconnecting office route can take a little longer than one
    # quarter second to return. Keep retries bounded and only retry transport
    # failures; authentication and protocol errors must still fail closed.
    CONNECT_RETRY_DELAYS_SECONDS = (0.25, 0.75, 1.5)

    config: StartConfiguration
    url: str
    token: str
    timeout_seconds: int
    organizer: TextOrganizer | None
    task_id: str = field(default_factory=lambda: str(uuid4()))
    websocket: ClientConnection | None = None
    reader_task: asyncio.Task[None] | None = None
    final_result: asyncio.Future[str] | None = None
    partials: asyncio.Queue[str] = field(default_factory=lambda: asyncio.Queue(maxsize=1))

    async def start(self) -> None:
        headers = {"Authorization": f"Bearer {self.token}"} if self.token else None
        last_error: OSError | None = None
        for attempt, delay in enumerate((0.0, *self.CONNECT_RETRY_DELAYS_SECONDS)):
            if delay:
                await asyncio.sleep(delay)
            try:
                self.websocket = await self._connect(headers)
                break
            except OSError as error:
                last_error = error
                if attempt == len(self.CONNECT_RETRY_DELAYS_SECONDS):
                    raise
        if self.websocket is None:
            # Defensive guard for static type checkers and unexpected loop changes.
            raise last_error or OSError("VoiceInk upstream connection failed")
        start = {
            "type": "start",
            "task_id": self.task_id,
            "sample_rate": 16_000,
            "channels": 1,
            "format": "pcm_s16le",
            "language": self._legacy_language(self.config.language),
            "partial_seconds": 0.8,
        }
        if self.config.hotwords:
            start["hotwords"] = self.config.hotwords
        await self.websocket.send(json.dumps(start, separators=(",", ":")))
        try:
            message = await asyncio.wait_for(self.websocket.recv(), self.timeout_seconds)
        except TimeoutError as exc:
            raise VoiceInkUpstreamError("VoiceInk upstream did not become ready") from exc
        payload = self._decode_message(message)
        self._validate_task_id(payload)
        message_type = payload.get("type")
        if message_type == "error":
            raise VoiceInkUpstreamError(
                self._error_message(payload, "VoiceInk upstream rejected the session")
            )
        if message_type != "ready":
            raise VoiceInkUpstreamError("VoiceInk upstream sent an event before ready")

        self.final_result = asyncio.get_running_loop().create_future()
        self.reader_task = asyncio.create_task(self._receive_events())

    async def feed(self, audio: bytes) -> str | None:
        websocket = self._require_websocket()
        await websocket.send(audio)
        latest: str | None = None
        while True:
            try:
                latest = self.partials.get_nowait()
            except asyncio.QueueEmpty:
                return latest

    async def finish(self) -> str:
        websocket = self._require_websocket()
        final_result = self.final_result
        if final_result is None:
            raise VoiceInkUpstreamError("VoiceInk upstream session was not started")
        await websocket.send('{"type":"end"}')
        try:
            transcript = await asyncio.wait_for(
                asyncio.shield(final_result),
                timeout=self.timeout_seconds,
            )
        except TimeoutError as exc:
            raise VoiceInkUpstreamError("VoiceInk upstream did not return final text") from exc
        if self.organizer is not None:
            return await self.organizer.organize(transcript, self.config)
        return transcript

    async def close(self) -> None:
        if self.reader_task is not None:
            self.reader_task.cancel()
            with suppress(asyncio.CancelledError):
                await self.reader_task
            self.reader_task = None
        if self.websocket is not None:
            await self.websocket.close()
            self.websocket = None
        if self.final_result is not None:
            if not self.final_result.done():
                self.final_result.cancel()
            elif not self.final_result.cancelled():
                self.final_result.exception()

    async def _receive_events(self) -> None:
        websocket = self._require_websocket()
        try:
            async for message in websocket:
                payload = self._decode_message(message)
                self._validate_task_id(payload)
                message_type = payload.get("type")
                if message_type == "partial":
                    self._publish_partial(self._transcript(payload, "partial"))
                elif message_type == "final":
                    self._resolve_final(self._transcript(payload, "final"))
                    return
                elif message_type == "error":
                    raise VoiceInkUpstreamError(
                        self._error_message(payload, "VoiceInk upstream recognition failed")
                    )
                else:
                    raise VoiceInkUpstreamError("VoiceInk upstream sent an unknown event")
            self._fail_final(VoiceInkUpstreamError("VoiceInk upstream closed before final text"))
        except asyncio.CancelledError:
            raise
        except ConnectionClosed:
            self._fail_final(VoiceInkUpstreamError("VoiceInk upstream connection closed"))
        except Exception as exc:
            error = exc if isinstance(exc, VoiceInkUpstreamError) else VoiceInkUpstreamError(
                "VoiceInk upstream event handling failed"
            )
            self._fail_final(error)

    def _require_websocket(self) -> ClientConnection:
        if self.websocket is None:
            raise VoiceInkUpstreamError("VoiceInk upstream session was not started")
        return self.websocket

    async def _connect(self, headers: dict[str, str] | None) -> ClientConnection:
        return await connect(
            self.url,
            additional_headers=headers,
            open_timeout=self.timeout_seconds,
            close_timeout=5,
            max_size=1_048_576,
        )

    def _validate_task_id(self, payload: dict[str, object]) -> None:
        upstream_task_id = payload.get("task_id")
        if upstream_task_id is not None and upstream_task_id != self.task_id:
            raise VoiceInkUpstreamError("VoiceInk upstream task ID does not match")

    def _resolve_final(self, transcript: str) -> None:
        if self.final_result is not None and not self.final_result.done():
            self.final_result.set_result(transcript)

    def _fail_final(self, error: BaseException) -> None:
        if self.final_result is not None and not self.final_result.done():
            self.final_result.set_exception(error)

    def _publish_partial(self, transcript: str) -> None:
        if self.partials.full():
            self.partials.get_nowait()
        self.partials.put_nowait(transcript)

    @staticmethod
    def _error_message(payload: dict[str, object], fallback: str) -> str:
        """Expose only a bounded, server-supplied diagnostic to the UI."""
        code = payload.get("code")
        message = payload.get("message")
        parts = [
            value.strip()
            for value in (
                str(code) if isinstance(code, str) else "",
                message if isinstance(message, str) else "",
            )
            if value and value.strip()
        ]
        if not parts:
            return fallback
        detail = ": ".join(parts)
        return f"{fallback}: {detail[:180]}"

    @staticmethod
    def _decode_message(message: str | bytes) -> dict[str, object]:
        try:
            decoded = cast(object, json.loads(message))
        except (json.JSONDecodeError, UnicodeDecodeError) as exc:
            raise VoiceInkUpstreamError("VoiceInk upstream returned invalid JSON") from exc
        if not isinstance(decoded, dict) or not all(isinstance(key, str) for key in decoded):
            raise VoiceInkUpstreamError("VoiceInk upstream returned an invalid event")
        return cast(dict[str, object], decoded)

    @staticmethod
    def _transcript(payload: dict[str, object], event_type: str) -> str:
        text = payload.get("text")
        if not isinstance(text, str):
            for container_name in ("result", "data"):
                container = payload.get(container_name)
                if isinstance(container, dict):
                    candidate = container.get("text")
                    if isinstance(candidate, str):
                        text = candidate
                        break
        if not isinstance(text, str) or len(text) > MAX_TRANSCRIPT_CHARS:
            raise VoiceInkUpstreamError(f"VoiceInk upstream {event_type} text is invalid")
        return text

    @staticmethod
    def _legacy_language(language: str) -> str:
        if language == "auto":
            return language
        return language.split("-", maxsplit=1)[0].lower()


@dataclass(frozen=True, slots=True)
class VoiceInkWebSocketBackendFactory:
    url: str
    token: str
    timeout_seconds: int
    organizer: TextOrganizer | None = None

    def create(self, config: StartConfiguration) -> VoiceInkWebSocketRecognitionSession:
        return VoiceInkWebSocketRecognitionSession(
            config=config,
            url=self.url,
            token=self.token,
            timeout_seconds=self.timeout_seconds,
            organizer=self.organizer,
        )
