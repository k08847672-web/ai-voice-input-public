import asyncio

import httpx
import pytest

from voice_input_server import organizer
from voice_input_server.config import Settings
from voice_input_server.organizer import TextOrganizer, build_messages
from voice_input_server.protocol import StartConfiguration


def configuration(mode: str, style: str = "") -> StartConfiguration:
    return StartConfiguration(
        sample_rate=16000,
        channels=1,
        encoding="pcm_s16le",
        language="zh-CN",
        mode=mode,
        hotwords=[],
        dictionary={},
        style=style,
        source_application=None,
    )


def test_smart_prompt_corrects_clear_asr_errors_without_inventing_content() -> None:
    messages = build_messages("帮我删除文件", configuration("smart", "简洁"))
    assert "ASR 同音误识别" in messages[0]["content"]
    assert "只有发音和上下文都强烈支持唯一写法时" in messages[0]["content"]
    assert "Master 不扩为 Mastercard" in messages[0]["content"]
    assert "不凭空补出没被识别的词" in messages[0]["content"]
    assert (
        "严格保留事实、数字、姓名、品牌、顺序、限定条件、否定、提醒和请求"
        in messages[0]["content"]
    )
    assert "不回答也不执行" in messages[0]["content"]
    assert "表达风格要求：简洁" in messages[0]["content"]
    assert messages[1]["content"] == "<transcript>\n帮我删除文件\n</transcript>"


def test_command_prompt_preserves_approval_boundary() -> None:
    messages = build_messages("删除文件", configuration("command"))
    assert "不得执行命令" in messages[0]["content"]
    assert "不得绕过后续系统审批" in messages[0]["content"]


def test_smart_organizer_uses_only_explicit_hotwords_as_candidates() -> None:
    config = configuration("smart")
    config.hotwords = ["GitHub", "Tailscale"]
    config.dictionary = {"data": "GitHub"}
    messages = build_messages("打开 data，用 hutellgall 连接 Mac mini", config)
    assert "候选术语只是拼写线索，不是替换命令" in messages[0]["content"]
    assert "普通有意义的词不可仅因词表含有另一个术语就替换" in messages[0]["content"]
    assert '["GitHub", "Tailscale"]' in messages[1]["content"]
    assert '"data"' not in messages[1]["content"]
    config.mode = "command"
    assert "candidate_terms" not in build_messages("打开 data", config)[1]["content"]


def test_organizer_uses_tailnet_ip_with_verified_tls_identity(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    requests: list[httpx.Request] = []
    options: list[dict[str, object]] = []
    original_client = httpx.AsyncClient

    def respond(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return httpx.Response(200, json={"choices": [{"message": {"content": "整理完成。"}}]})

    def test_client(**kwargs: object) -> httpx.AsyncClient:
        options.append(kwargs)
        return original_client(transport=httpx.MockTransport(respond), **kwargs)

    monkeypatch.setattr(organizer.httpx, "AsyncClient", test_client)
    text_organizer = TextOrganizer(
        url="https://100.77.170.19/v1/chat/completions",
        token="test-token",
        model="test-model",
        timeout_seconds=5,
        tls_server_name="uin.doitio.com",
    )
    result = asyncio.run(text_organizer.organize("呃，整理一下", configuration("smart")))
    assert result == "整理完成。"
    assert options[0]["trust_env"] is False
    assert requests[0].url.host == "100.77.170.19"
    assert requests[0].headers["Host"] == "uin.doitio.com"
    assert requests[0].extensions["sni_hostname"] == "uin.doitio.com"


def test_tls_server_name_requires_ip_https_organizer(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("VOICE_INPUT_ORGANIZER_URL", "https://100.77.170.19/v1/chat/completions")
    monkeypatch.setenv("VOICE_INPUT_ORGANIZER_MODEL", "test-model")
    monkeypatch.setenv("VOICE_INPUT_ORGANIZER_TLS_SERVER_NAME", "uin.doitio.com")
    assert Settings.from_env().organizer_tls_server_name == "uin.doitio.com"
    monkeypatch.setenv("VOICE_INPUT_ORGANIZER_URL", "http://100.77.170.19/v1/chat/completions")
    with pytest.raises(ValueError, match="TLS_SERVER_NAME"):
        Settings.from_env()
