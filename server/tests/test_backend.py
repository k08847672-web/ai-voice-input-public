import asyncio
import wave
from io import BytesIO

import pytest

from voice_input_server.backends.openai_http import OpenAIHTTPRecognitionSession
from voice_input_server.config import Settings
from voice_input_server.protocol import StartConfiguration


def configuration() -> StartConfiguration:
    return StartConfiguration(
        sample_rate=16000,
        channels=1,
        encoding="pcm_s16le",
        language="zh-CN",
        mode="faithful",
        hotwords=[],
        dictionary={},
        style="",
        source_application=None,
    )


def test_http_adapter_wraps_pcm_in_valid_wav() -> None:
    session = OpenAIHTTPRecognitionSession(
        config=configuration(),
        url="http://127.0.0.1/transcriptions",
        token="",
        model="test",
        timeout_seconds=1,
        organizer=None,
    )
    asyncio.run(session.feed(bytes(3_200)))
    with wave.open(BytesIO(session._wav_data()), "rb") as wav:
        assert wav.getnchannels() == 1
        assert wav.getsampwidth() == 2
        assert wav.getframerate() == 16_000
        assert wav.getnframes() == 1_600


def test_production_requires_bearer_token() -> None:
    settings = Settings(
        environment="production",
        bearer_token="",
        backend="mock",
        mock_transcript="test",
        max_audio_bytes=100,
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
    with pytest.raises(ValueError, match="BEARER_TOKEN"):
        settings.validate()


def test_upstream_url_rejects_embedded_credentials() -> None:
    settings = Settings(
        environment="development",
        bearer_token="test",
        backend="openai-http",
        mock_transcript="test",
        max_audio_bytes=100,
        max_session_seconds=10,
        max_concurrent_sessions=1,
        shutdown_grace_seconds=1,
        backend_close_timeout_seconds=1,
        openai_url="https://secret@example.com/transcriptions",
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
    with pytest.raises(ValueError, match="without credentials"):
        settings.validate()
