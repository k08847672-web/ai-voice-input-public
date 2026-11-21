from __future__ import annotations

import asyncio
import hmac
import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from json import JSONDecodeError
from pathlib import Path
from time import monotonic
from typing import Literal
from uuid import UUID

from fastapi import FastAPI, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse
from pydantic import ValidationError

from voice_input_server.backends import (
    BackendFactory,
    MockBackendFactory,
    OpenAIHTTPBackendFactory,
    VoiceInkWebSocketBackendFactory,
)
from voice_input_server.backends.base import RecognitionSession
from voice_input_server.config import Settings
from voice_input_server.dictionary_sync import MAX_FILE_BYTES, DictionarySnapshot, DictionaryStore
from voice_input_server.organizer import TextOrganizer
from voice_input_server.protocol import (
    MAX_TRANSCRIPT_CHARS,
    StartMessage,
    StopMessage,
    error,
    final,
    partial,
    ready,
)

logger = logging.getLogger("voice_input_server")


RegistrationResult = Literal["accepted", "draining", "limited"]


class BackendOutputError(Exception):
    pass


def _safe_backend_error(exc: BaseException, fallback: str = "recognition backend failed") -> str:
    """Return a short diagnostic without exposing a traceback or raw payload."""
    detail = str(exc).strip()
    if not detail:
        return fallback
    normalized = " ".join(detail.split())
    return normalized[:180]


class SessionRegistry:
    def __init__(self, limit: int) -> None:
        self.limit = limit
        self._connections: set[WebSocket] = set()
        self._accepting = True
        self._lock = asyncio.Lock()
        self._drained = asyncio.Event()
        self._drained.set()

    async def register(self, websocket: WebSocket) -> RegistrationResult:
        async with self._lock:
            if not self._accepting:
                return "draining"
            if len(self._connections) >= self.limit:
                return "limited"
            self._connections.add(websocket)
            self._drained.clear()
            return "accepted"

    async def unregister(self, websocket: WebSocket) -> None:
        async with self._lock:
            self._connections.discard(websocket)
            if not self._connections:
                self._drained.set()

    async def is_ready(self) -> bool:
        async with self._lock:
            return self._accepting

    async def begin_shutdown(self, timeout_seconds: int) -> bool:
        async with self._lock:
            self._accepting = False
            if not self._connections:
                return True
        try:
            async with asyncio.timeout(timeout_seconds):
                await self._drained.wait()
            return True
        except TimeoutError:
            async with self._lock:
                remaining = list(self._connections)
            await asyncio.gather(
                *(self._close_for_restart(websocket) for websocket in remaining)
            )
            return False

    @staticmethod
    async def _close_for_restart(websocket: WebSocket) -> None:
        try:
            await websocket.close(code=1012, reason="server restart")
        except (RuntimeError, WebSocketDisconnect):
            pass


def backend_from_settings(settings: Settings) -> BackendFactory:
    organizer = None
    if settings.organizer_url:
        organizer = TextOrganizer(
            url=settings.organizer_url,
            token=settings.organizer_token,
            model=settings.organizer_model,
            timeout_seconds=settings.organizer_timeout_seconds,
            tls_server_name=settings.organizer_tls_server_name,
        )
    if settings.backend == "openai-http":
        return OpenAIHTTPBackendFactory(
            url=settings.openai_url,
            token=settings.openai_token,
            model=settings.openai_model,
            timeout_seconds=settings.openai_timeout_seconds,
            organizer=organizer,
        )
    if settings.backend == "voiceink-websocket":
        return VoiceInkWebSocketBackendFactory(
            url=settings.voiceink_url,
            token=settings.voiceink_token,
            timeout_seconds=settings.voiceink_timeout_seconds,
            organizer=organizer,
        )
    return MockBackendFactory(settings.mock_transcript)


def create_app(
    settings: Settings | None = None,
    backend_factory: BackendFactory | None = None,
) -> FastAPI:
    settings = settings or Settings.from_env()
    backend_factory = backend_factory or backend_from_settings(settings)
    sessions = SessionRegistry(settings.max_concurrent_sessions)
    dictionary_store = None
    if settings.dictionary_sync_dir:
        dictionary_store = DictionaryStore(Path(settings.dictionary_sync_dir))

    @asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncIterator[None]:
        logger.info("server_started", extra={"backend": settings.backend})
        try:
            yield
        finally:
            drained = await sessions.begin_shutdown(settings.shutdown_grace_seconds)
            logger.info("server_stopped", extra={"sessions_drained": drained})

    app = FastAPI(title="VoiceInput ASR adapter", version="1.0.0", lifespan=lifespan)

    @app.get("/healthz")
    async def healthz() -> dict[str, str]:
        return {"status": "ok", "protocol": "1"}

    @app.get("/readyz", response_model=None)
    async def readyz() -> JSONResponse:
        ready_for_traffic = await sessions.is_ready()
        return JSONResponse(
            {"status": "ready" if ready_for_traffic else "draining", "protocol": "1"},
            status_code=200 if ready_for_traffic else 503,
        )

    @app.get("/v1/dictionary", response_model=None)
    async def get_dictionary(request: Request) -> JSONResponse:
        if not _http_authorized(request, settings.bearer_token):
            return JSONResponse({"error": "unauthorized"}, status_code=401)
        if dictionary_store is None:
            return JSONResponse({"error": "sync_unavailable"}, status_code=503)
        snapshot = await dictionary_store.read()
        return JSONResponse(snapshot.model_dump(), headers={"Cache-Control": "no-store"})

    @app.put("/v1/dictionary", response_model=None)
    async def put_dictionary(request: Request) -> JSONResponse:
        if not _http_authorized(request, settings.bearer_token):
            return JSONResponse({"error": "unauthorized"}, status_code=401)
        if dictionary_store is None:
            return JSONResponse({"error": "sync_unavailable"}, status_code=503)
        body = await request.body()
        if len(body) > MAX_FILE_BYTES:
            return JSONResponse({"error": "dictionary_too_large"}, status_code=413)
        try:
            snapshot = DictionarySnapshot.model_validate_json(body)
        except ValidationError:
            return JSONResponse({"error": "invalid_dictionary"}, status_code=400)
        candidate = request.headers.get("if-match", "")
        if candidate != str(snapshot.revision):
            return JSONResponse({"error": "invalid_revision"}, status_code=400)
        updated = await dictionary_store.replace(snapshot.revision, snapshot.entries)
        if updated is None:
            return JSONResponse({"error": "revision_conflict"}, status_code=409)
        return JSONResponse(updated.model_dump(), headers={"Cache-Control": "no-store"})

    @app.websocket("/v1/asr/stream")
    async def stream(websocket: WebSocket) -> None:
        await serve_stream(websocket, settings.bearer_token)

    if settings.friend_bearer_token:
        @app.websocket("/v1/asr/trial")
        async def trial(websocket: WebSocket) -> None:
            await serve_stream(websocket, settings.friend_bearer_token)

    async def serve_stream(websocket: WebSocket, expected_token: str) -> None:
        if not _authorized(websocket, expected_token):
            await websocket.close(code=4401, reason="unauthorized")
            return
        registration = await sessions.register(websocket)
        if registration == "draining":
            await websocket.close(code=1012, reason="server restart")
            return
        if registration == "limited":
            await websocket.close(code=4429, reason="too many sessions")
            return
        try:
            await websocket.accept()
        except (RuntimeError, WebSocketDisconnect):
            await sessions.unregister(websocket)
            return
        session: RecognitionSession | None = None
        session_id: UUID | None = None
        audio_bytes = 0
        outcome = "disconnected"
        started_at = monotonic()
        try:
            try:
                raw_start = await asyncio.wait_for(websocket.receive_json(), timeout=10)
                start = StartMessage.model_validate(raw_start)
            except (JSONDecodeError, KeyError, TypeError, ValidationError):
                outcome = "invalid_message"
                await _send_error(
                    websocket,
                    None,
                    "invalid_message",
                    "start message validation failed",
                )
                return
            session_id = start.session_id
            session = backend_factory.create(start.config)
            await session.start()
            await websocket.send_json(ready(session_id).wire())

            async with asyncio.timeout(settings.max_session_seconds):
                while True:
                    message = await websocket.receive()
                    message_type = message.get("type")
                    if message_type == "websocket.disconnect":
                        break
                    if message_type != "websocket.receive":
                        outcome = "invalid_message"
                        await _send_error(
                            websocket,
                            session_id,
                            "invalid_message",
                            "expected WebSocket receive message",
                        )
                        break
                    audio = message.get("bytes")
                    if audio is not None:
                        if not audio:
                            outcome = "invalid_message"
                            await _send_error(
                                websocket,
                                session_id,
                                "invalid_message",
                                "audio frame must not be empty",
                            )
                            break
                        audio_bytes += len(audio)
                        if audio_bytes > settings.max_audio_bytes:
                            outcome = "audio_limit"
                            await _send_error(
                                websocket,
                                session_id,
                                "audio_limit",
                                "audio session is too large",
                            )
                            break
                        current_partial = await session.feed(audio)
                        if current_partial is not None:
                            if (
                                not isinstance(current_partial, str)
                                or len(current_partial) > MAX_TRANSCRIPT_CHARS
                            ):
                                raise BackendOutputError(
                                    "backend returned invalid partial transcript"
                                )
                            await websocket.send_json(partial(session_id, current_partial).wire())
                        continue

                    text = message.get("text")
                    if text is None:
                        outcome = "invalid_message"
                        await _send_error(
                            websocket,
                            session_id,
                            "invalid_message",
                            "expected binary audio or stop",
                        )
                        break
                    stop = StopMessage.model_validate_json(text)
                    if stop.session_id != session_id:
                        outcome = "session_mismatch"
                        await _send_error(
                            websocket,
                            session_id,
                            "session_mismatch",
                            "stop session_id does not match",
                        )
                        break
                    transcript = await session.finish()
                    if not isinstance(transcript, str) or len(transcript) > MAX_TRANSCRIPT_CHARS:
                        raise BackendOutputError("backend returned invalid final transcript")
                    await websocket.send_json(final(session_id, transcript).wire())
                    outcome = "completed"
                    return
        except TimeoutError:
            outcome = "timeout"
            await _send_error(websocket, session_id, "timeout", "recognition session timed out")
        except ValidationError:
            outcome = "invalid_message"
            await _send_error(websocket, session_id, "invalid_message", "message validation failed")
        except WebSocketDisconnect:
            outcome = "disconnected"
        except BackendOutputError:
            outcome = "backend_error"
            logger.warning(
                "recognition_backend_output_invalid",
                extra={"session_id": str(session_id)},
            )
            await _send_error(websocket, session_id, "backend_error", "recognition backend failed")
        except Exception as exc:
            outcome = "backend_error"
            logger.exception("recognition_session_failed", extra={"session_id": str(session_id)})
            await _send_error(
                websocket,
                session_id,
                "backend_error",
                _safe_backend_error(exc),
            )
        finally:
            try:
                if session is not None:
                    try:
                        async with asyncio.timeout(settings.backend_close_timeout_seconds):
                            await session.close()
                    except TimeoutError:
                        logger.warning(
                            "recognition_session_close_timed_out",
                            extra={"session_id": str(session_id)},
                        )
                    except Exception:
                        logger.exception(
                            "recognition_session_close_failed",
                            extra={"session_id": str(session_id)},
                        )
            finally:
                await _close_websocket(websocket)
                await sessions.unregister(websocket)
                logger.info(
                    "recognition_session_closed",
                    extra={
                        "session_id": str(session_id),
                        "outcome": outcome,
                        "duration_ms": round((monotonic() - started_at) * 1000),
                    },
                )

    return app


def _authorized(websocket: WebSocket, expected_token: str) -> bool:
    if not expected_token:
        return True
    authorization = websocket.headers.get("authorization", "")
    scheme, _, candidate = authorization.partition(" ")
    return scheme.lower() == "bearer" and hmac.compare_digest(
        candidate.encode(), expected_token.encode()
    )


def _http_authorized(request: Request, expected_token: str) -> bool:
    if not expected_token:
        return False
    scheme, _, candidate = request.headers.get("authorization", "").partition(" ")
    return scheme.lower() == "bearer" and hmac.compare_digest(candidate, expected_token)


async def _send_error(
    websocket: WebSocket,
    session_id: UUID | None,
    code: str,
    message: str,
) -> None:
    try:
        await websocket.send_json(error(session_id, code, message).wire())
    except (RuntimeError, WebSocketDisconnect):
        pass


async def _close_websocket(websocket: WebSocket) -> None:
    try:
        await websocket.close(code=1000)
    except (RuntimeError, WebSocketDisconnect):
        pass


app = create_app()
