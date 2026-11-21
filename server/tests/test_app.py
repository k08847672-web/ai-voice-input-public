import asyncio
from dataclasses import replace
from typing import cast

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocket, WebSocketDisconnect

from voice_input_server.app import SessionRegistry, create_app
from voice_input_server.backends.mock import MockBackendFactory
from voice_input_server.config import Settings


def settings(token: str = "test-secret") -> Settings:
    return Settings(
        environment="test",
        bearer_token=token,
        backend="mock",
        mock_transcript="你好，世界。",
        max_audio_bytes=1_000_000,
        max_session_seconds=10,
        max_concurrent_sessions=1,
        shutdown_grace_seconds=1,
        backend_close_timeout_seconds=1,
        openai_url="",
        openai_token="",
        openai_model="whisper-1",
        openai_timeout_seconds=10,
        voiceink_url="",
        voiceink_token="",
        voiceink_timeout_seconds=10,
        organizer_url="",
        organizer_token="",
        organizer_model="",
        organizer_timeout_seconds=10,
    )


def start_message(session_id: str) -> dict[str, object]:
    return {
        "type": "start",
        "session_id": session_id,
        "protocol_version": 1,
        "config": {
            "sample_rate": 16000,
            "channels": 1,
            "encoding": "pcm_s16le",
            "language": "zh-CN",
            "mode": "smart",
            "hotwords": [],
            "dictionary": {},
            "style": "",
            "source_application": "com.apple.TextEdit",
        },
    }


def test_health_does_not_expose_configuration() -> None:
    client = TestClient(create_app(settings()))
    assert client.get("/healthz").json() == {"status": "ok", "protocol": "1"}
    assert client.get("/readyz").json() == {"status": "ready", "protocol": "1"}


def test_websocket_contract_from_start_to_final() -> None:
    session_id = "c56a4180-65aa-42ec-a945-5fd21dec0538"
    app = create_app(settings(), MockBackendFactory("你好，世界。"))
    with TestClient(app) as client:
        with client.websocket_connect(
            "/v1/asr/stream", headers={"Authorization": "Bearer test-secret"}
        ) as websocket:
            websocket.send_json(start_message(session_id))
            assert websocket.receive_json() == {"type": "ready", "session_id": session_id}
            websocket.send_bytes(bytes(32_000))
            partial = websocket.receive_json()
            assert partial["type"] == "partial"
            assert partial["session_id"] == session_id
            websocket.send_json({"type": "stop", "session_id": session_id})
            assert websocket.receive_json() == {
                "type": "final",
                "session_id": session_id,
                "text": "你好，世界。",
            }


def test_websocket_rejects_bad_token() -> None:
    app = create_app(settings())
    with TestClient(app) as client:
        with pytest.raises(WebSocketDisconnect) as caught:
            with client.websocket_connect(
                "/v1/asr/stream", headers={"Authorization": "Bearer wrong"}
            ):
                pass
        assert caught.value.code == 4401


@pytest.mark.parametrize(
    ("path", "token", "allowed"),
    [
        ("/v1/asr/stream", "test-secret", True),
        ("/v1/asr/stream", "friend-secret", False),
        ("/v1/asr/trial", "friend-secret", True),
        ("/v1/asr/trial", "test-secret", False),
        ("/v1/asr/trial", "wrong", False),
        ("/v1/asr/trial", "é", False),
        ("/v1/asr/trial", "", False),
    ],
)
def test_stream_authentication_isolated(path: str, token: str, allowed: bool) -> None:
    app = create_app(replace(settings(), friend_bearer_token="friend-secret"))
    headers = {b"Authorization": f"Bearer {token}".encode("latin-1")} if token else {}
    with TestClient(app) as client:
        if allowed:
            with client.websocket_connect(path, headers=headers):
                pass
        else:
            with pytest.raises(WebSocketDisconnect) as caught:
                with client.websocket_connect(path, headers=headers):
                    pass
            assert caught.value.code == 4401


def test_trial_stream_is_disabled_without_token() -> None:
    with TestClient(create_app(settings(token=""))) as client:
        with pytest.raises(WebSocketDisconnect):
            with client.websocket_connect("/v1/asr/trial"):
                pass


def test_websocket_enforces_concurrency_limit() -> None:
    first_session = "c56a4180-65aa-42ec-a945-5fd21dec0538"
    app = create_app(settings())
    with TestClient(app) as client:
        with client.websocket_connect(
            "/v1/asr/stream", headers={"Authorization": "Bearer test-secret"}
        ) as first:
            first.send_json(start_message(first_session))
            assert first.receive_json()["type"] == "ready"
            with pytest.raises(WebSocketDisconnect) as caught:
                with client.websocket_connect(
                    "/v1/asr/stream", headers={"Authorization": "Bearer test-secret"}
                ):
                    pass
            assert caught.value.code == 4429


@pytest.mark.parametrize("binary", [False, True])
def test_websocket_rejects_malformed_start_without_backend_error(binary: bool) -> None:
    app = create_app(settings())
    with TestClient(app) as client:
        with client.websocket_connect(
            "/v1/asr/stream", headers={"Authorization": "Bearer test-secret"}
        ) as websocket:
            if binary:
                websocket.send_bytes(b"not-json")
            else:
                websocket.send_text("not-json")
            assert websocket.receive_json() == {
                "type": "error",
                "code": "invalid_message",
                "message": "start message validation failed",
            }


def test_websocket_rejects_empty_audio_frame() -> None:
    session_id = "c56a4180-65aa-42ec-a945-5fd21dec0538"
    app = create_app(settings())
    with TestClient(app) as client:
        with client.websocket_connect(
            "/v1/asr/stream", headers={"Authorization": "Bearer test-secret"}
        ) as websocket:
            websocket.send_json(start_message(session_id))
            assert websocket.receive_json()["type"] == "ready"
            websocket.send_bytes(b"")
            assert websocket.receive_json() == {
                "type": "error",
                "session_id": session_id,
                "code": "invalid_message",
                "message": "audio frame must not be empty",
            }


def test_session_registry_drains_and_rejects_new_sessions() -> None:
    async def scenario() -> None:
        registry = SessionRegistry(limit=1)
        first = cast(WebSocket, object())
        second = cast(WebSocket, object())
        assert await registry.register(first) == "accepted"
        assert await registry.register(second) == "limited"

        shutdown = asyncio.create_task(registry.begin_shutdown(timeout_seconds=1))
        await asyncio.sleep(0)
        assert not await registry.is_ready()
        assert await registry.register(second) == "draining"
        await registry.unregister(first)
        assert await shutdown

    asyncio.run(scenario())


def test_session_registry_force_closes_after_grace_period() -> None:
    class FakeWebSocket:
        close_code: int | None = None

        async def close(self, code: int, reason: str) -> None:
            del reason
            self.close_code = code

    async def scenario() -> None:
        registry = SessionRegistry(limit=1)
        websocket = FakeWebSocket()
        assert await registry.register(cast(WebSocket, websocket)) == "accepted"
        assert not await registry.begin_shutdown(timeout_seconds=0)
        assert websocket.close_code == 1012

    asyncio.run(scenario())
