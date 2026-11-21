import asyncio
import json
from unittest.mock import patch

from websockets.asyncio.server import ServerConnection, serve

from voice_input_server.backends.voiceink_websocket import (
    VoiceInkWebSocketRecognitionSession,
)
from voice_input_server.protocol import StartConfiguration


def configuration(mode: str = "faithful") -> StartConfiguration:
    return StartConfiguration(
        sample_rate=16000,
        channels=1,
        encoding="pcm_s16le",
        language="zh-CN",
        mode=mode,
        hotwords=[],
        dictionary={},
        style="",
        source_application=None,
    )


def test_voiceink_backend_streams_audio_and_returns_final() -> None:
    async def scenario() -> None:
        async def handler(websocket: ServerConnection) -> None:
            raw_start = await websocket.recv()
            assert isinstance(raw_start, str)
            start = json.loads(raw_start)
            assert start["type"] == "start"
            assert start["language"] == "zh"
            assert "hotwords" not in start
            task_id = start["task_id"]
            await websocket.send(json.dumps({"type": "ready", "task_id": task_id}))

            audio = await websocket.recv()
            assert audio == b"pcm"
            await websocket.send(
                json.dumps({"type": "partial", "task_id": task_id, "text": "你好"})
            )
            assert await websocket.recv() == '{"type":"end"}'
            await websocket.send(
                json.dumps({"type": "final", "task_id": task_id, "result": {"text": "你好。"}})
            )

        async with serve(handler, "127.0.0.1", 0) as upstream:
            port = upstream.sockets[0].getsockname()[1]
            session = VoiceInkWebSocketRecognitionSession(
                config=configuration(),
                url=f"ws://127.0.0.1:{port}/api/voice-input/stream",
                token="",
                timeout_seconds=2,
                organizer=None,
            )
            await session.start()
            assert await session.feed(b"pcm") is None
            assert await asyncio.wait_for(session.partials.get(), 1) == "你好"
            assert await session.finish() == "你好。"
            await session.close()

    asyncio.run(scenario())


def test_voiceink_backend_passes_explicit_hotwords_to_upstream() -> None:
    async def scenario() -> None:
        async def handler(websocket: ServerConnection) -> None:
            raw_start = await websocket.recv()
            assert isinstance(raw_start, str)
            start = json.loads(raw_start)
            assert start["hotwords"] == ["GitHub", "Tailscale"]
            assert "dictionary" not in start
            await websocket.send(json.dumps({"type": "ready", "task_id": start["task_id"]}))

        async with serve(handler, "127.0.0.1", 0) as upstream:
            port = upstream.sockets[0].getsockname()[1]
            config = configuration()
            config.hotwords = ["GitHub", "Tailscale"]
            config.dictionary = {"data": "GitHub"}
            session = VoiceInkWebSocketRecognitionSession(
                config=config,
                url=f"ws://127.0.0.1:{port}/api/voice-input/stream",
                token="",
                timeout_seconds=2,
                organizer=None,
            )
            await session.start()
            await session.close()

    asyncio.run(scenario())


def test_voiceink_backend_retries_transient_transport_failure() -> None:
    async def scenario() -> None:
        async def handler(websocket: ServerConnection) -> None:
            raw_start = await websocket.recv()
            assert isinstance(raw_start, str)
            task_id = json.loads(raw_start)["task_id"]
            await websocket.send(json.dumps({"type": "ready", "task_id": task_id}))
            assert await websocket.recv() == b"pcm"
            assert await websocket.recv() == '{"type":"end"}'
            await websocket.send(
                json.dumps({"type": "final", "task_id": task_id, "text": "你好。"})
            )

        async with serve(handler, "127.0.0.1", 0) as upstream:
            port = upstream.sockets[0].getsockname()[1]
            session = VoiceInkWebSocketRecognitionSession(
                config=configuration(),
                url=f"ws://127.0.0.1:{port}/api/voice-input/stream",
                token="",
                timeout_seconds=2,
                organizer=None,
            )
            attempts = 0
            original_connect = VoiceInkWebSocketRecognitionSession._connect

            async def flaky_connect(
                self: VoiceInkWebSocketRecognitionSession,
                headers: dict[str, str] | None,
            ):
                nonlocal attempts
                attempts += 1
                if attempts == 1:
                    raise OSError("temporary route failure")
                return await original_connect(self, headers)

            with patch.object(
                VoiceInkWebSocketRecognitionSession,
                "_connect",
                new=flaky_connect,
            ), patch.object(
                VoiceInkWebSocketRecognitionSession,
                "CONNECT_RETRY_DELAYS_SECONDS",
                (0.0,),
            ):
                await session.start()
                assert await session.feed(b"pcm") is None
                assert await session.finish() == "你好。"
                assert attempts == 2
            await session.close()

    asyncio.run(scenario())
