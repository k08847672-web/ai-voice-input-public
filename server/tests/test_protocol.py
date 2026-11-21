import json
from pathlib import Path
from uuid import UUID

import pytest
from pydantic import ValidationError

from voice_input_server.protocol import StartMessage, StopMessage, error, final, partial, ready

SESSION_ID = "c56a4180-65aa-42ec-a945-5fd21dec0538"
FIXTURE_PATH = (
    Path(__file__).resolve().parents[2]
    / "Tests"
    / "VoiceInputCoreTests"
    / "Fixtures"
    / "asr_v1.json"
)


def start_payload() -> dict[str, object]:
    return {
        "type": "start",
        "session_id": SESSION_ID,
        "protocol_version": 1,
        "config": {
            "sample_rate": 16000,
            "channels": 1,
            "encoding": "pcm_s16le",
            "language": "zh-CN",
            "mode": "smart",
            "hotwords": ["Codex"],
            "dictionary": {"扣得克斯": "Codex"},
            "style": "简洁",
            "source_application": "com.apple.TextEdit",
        },
    }


def test_start_message_accepts_protocol_v1() -> None:
    message = StartMessage.model_validate(start_payload())
    assert message.session_id == UUID(SESSION_ID)
    assert message.config.sample_rate == 16000
    assert message.config.mode == "smart"


def test_unknown_fields_are_rejected() -> None:
    payload = start_payload()
    payload["unexpected"] = True
    with pytest.raises(ValidationError):
        StartMessage.model_validate(payload)


def test_server_messages_omit_null_fields() -> None:
    message = final(UUID(SESSION_ID), "你好").wire()
    assert message == {"type": "final", "session_id": SESSION_ID, "text": "你好"}
    assert error(None, "bad", "invalid").wire() == {
        "type": "error",
        "code": "bad",
        "message": "invalid",
    }


def test_shared_protocol_fixture_matches_python_models() -> None:
    fixture = json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))
    session_id = UUID(fixture["session_id"])

    start = StartMessage.model_validate(fixture["client"]["start"])
    stop = StopMessage.model_validate(fixture["client"]["stop"])
    assert start.model_dump(mode="json", by_alias=True) == fixture["client"]["start"]
    assert stop.model_dump(mode="json", by_alias=True) == fixture["client"]["stop"]

    expected_server_messages = [
        ready(session_id).wire(),
        partial(session_id, "今天下午").wire(),
        final(session_id, "今天下午三点开会。").wire(),
        error(session_id, "overloaded", "服务繁忙").wire(),
    ]
    assert expected_server_messages == fixture["server"]


def test_server_message_content_limits_are_enforced() -> None:
    with pytest.raises(ValidationError):
        final(UUID(SESSION_ID), "字" * 100_001)
    with pytest.raises(ValidationError):
        error(UUID(SESSION_ID), "backend_error", "x" * 1_001)
