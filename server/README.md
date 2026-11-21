# VoiceInput ASR 协议适配服务

该服务用于验证客户端协议，并在 ASR 只提供 OpenAI-compatible HTTP 转写接口时提供适配。它不是 N150 网关，也不提供节点切换。

开发模式默认使用 `mock` 后端：

```bash
python3 -m venv .venv
.venv/bin/pip install --requirement requirements-dev.lock
.venv/bin/pip install --no-deps --editable .
VOICE_INPUT_BEARER_TOKEN=development-token .venv/bin/uvicorn voice_input_server.app:app --port 8765
```

客户端配置 `ws://127.0.0.1:8765/v1/asr/stream`，并打开“允许本机 ws:// 调试”。

若重装后的 ASR 提供 OpenAI-compatible `/audio/transcriptions` 接口：

```bash
export VOICE_INPUT_ENV=production
export VOICE_INPUT_BEARER_TOKEN='replace-with-a-long-random-token'
export VOICE_INPUT_BACKEND=openai-http
export VOICE_INPUT_OPENAI_URL='http://127.0.0.1:8000/v1/audio/transcriptions'
export VOICE_INPUT_OPENAI_MODEL='your-model-name'
uvicorn voice_input_server.app:app --host 127.0.0.1 --port 8765
```

`openai-http` 只能在松开后返回最终结果。要获得实时 partial transcript，应让 ASR 原生实现 [`docs/ASR_PROTOCOL.md`](../docs/ASR_PROTOCOL.md)，或新增一个实现 `RecognitionSession` 的流式后端。

若已有 VoiceInk `start → PCM → end` 流式服务，可在同一受控私网中用标准 v1 适配入口代理：

```bash
export VOICE_INPUT_ENV=production
export VOICE_INPUT_BEARER_TOKEN='replace-with-a-long-random-token'
export VOICE_INPUT_BACKEND=voiceink-websocket
export VOICE_INPUT_VOICEINK_URL='ws://127.0.0.1:8765/api/voice-input/stream'
uvicorn voice_input_server.app:app --host 127.0.0.1 --port 8766
```

该后端在向客户端返回 ready 前先连接上游，转发 PCM 和 partial，并在 final 后按模式可选调用下述整理器。

若 ASR 只负责忠实转写，可同时配置 OpenAI-compatible
`/chat/completions` 小模型：

```bash
export VOICE_INPUT_ORGANIZER_URL='http://127.0.0.1:8001/v1/chat/completions'
export VOICE_INPUT_ORGANIZER_MODEL='your-small-instruct-model'
```

整理器只处理 `smart` 和 `command`；`faithful` 直接返回 ASR 文本。它不执行转写中的命令，且不会
成为另一条 ASR 或客户端故障切换链路。若整理器不在办公室内网，必须使用 TLS、项目独立令牌和不记录正文的受控服务；只发送 final 文字，不得外发音频。

生产镜像和 CI 使用 lock 文件中的精确版本。升级依赖时应在隔离虚拟环境中重新解析、运行完整测试，
再同时更新 `pyproject.toml` 的兼容范围、lock 文件和第三方许可记录；不能只修改其中一个。

容器存活检查使用 `/healthz`，反向代理摘流应使用 `/readyz`。收到停机后，服务停止接收新会话并按
`VOICE_INPUT_SHUTDOWN_GRACE_SECONDS` 排空；超时连接收到 WebSocket 1012。服务日志只记录会话 ID、
结果类别和耗时等无内容字段，不记录音频、转写、词典、上游响应正文或 Authorization header。
