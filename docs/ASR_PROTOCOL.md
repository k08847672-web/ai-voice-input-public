# ASR WebSocket 协议 v1

## 连接

- 路径建议：`/v1/asr/stream`
- 生产传输：TLS WebSocket (`wss://`)
- 鉴权：`Authorization: Bearer <token>`
- 每个 WebSocket 只承载一个识别会话；结束后由客户端关闭。
- 文本控制消息使用 UTF-8 JSON；音频使用 WebSocket binary frame。

## 顺序

1. 客户端连接后首先发送 `start`。
2. 服务端验证配置并发送 `ready`。
3. 客户端按采集顺序发送二进制 PCM 分片；服务端可发送任意数量的 `partial`。
4. 用户松开快捷键，或在切换模式下再次按下快捷键后，客户端发送 `stop`，不再发送音频。
5. 服务端处理尾部音频后只发送一次 `final`，随后客户端关闭连接。
6. 任一不可恢复错误用 `error` 表示；发送后服务端应结束会话。

所有包含 `session_id` 的服务端消息必须与 `start` 一致。客户端遇到不一致会立即拒绝会话。

## 客户端消息

`start`：

```json
{
  "type": "start",
  "session_id": "c56a4180-65aa-42ec-a945-5fd21dec0538",
  "protocol_version": 1,
  "config": {
    "sample_rate": 16000,
    "channels": 1,
    "encoding": "pcm_s16le",
    "language": "zh-CN",
    "mode": "smart",
    "hotwords": ["Codex"],
    "dictionary": {"扣得克斯": "Codex"},
    "style": "技术说明，简洁",
    "source_application": "com.apple.TextEdit"
  }
}
```

`sample_rate`、`channels` 和 `encoding` 在 v1 中固定。`mode` 取值：

- `faithful`：只处理标点、明显重复和识别错误，保留说法。
- `smart`：去口头语、合并自我纠正并整理结构，不能添加原文没有的信息。
- `command`：输出清晰的命令文本，但服务端不得直接执行命令。

音频分片为裸 PCM，不包含 WAV 头。建议每个 binary frame 覆盖 20–150 ms 音频。

`stop`：

```json
{
  "type": "stop",
  "session_id": "c56a4180-65aa-42ec-a945-5fd21dec0538"
}
```

## 服务端消息

```json
{"type":"ready","session_id":"c56a4180-65aa-42ec-a945-5fd21dec0538"}
{"type":"partial","session_id":"c56a4180-65aa-42ec-a945-5fd21dec0538","text":"今天下午"}
{"type":"final","session_id":"c56a4180-65aa-42ec-a945-5fd21dec0538","text":"今天下午三点开会。"}
{"type":"error","session_id":"c56a4180-65aa-42ec-a945-5fd21dec0538","code":"overloaded","message":"服务繁忙"}
```

建议的稳定错误码：`unauthorized`、`invalid_message`、`unsupported_audio`、`audio_limit`、
`overloaded`、`backend_error`、`timeout`。`message` 可显示给用户，但不得包含服务端凭据或堆栈。

## 限额与保活

- 参考服务默认单会话最长 180 秒、音频最多 64 MiB、并发会话最多 4 个。
- 反向代理的空闲超时必须高于单会话上限。
- 客户端当前依赖 WebSocket/系统 TCP 保活，不定义应用层 ping 消息。
- 服务端应对同一设备的并发会话、总并发与速率单独限流。

协议模型的权威实现位于 `Sources/VoiceInputCore/ASRProtocol.swift` 与
`server/src/voice_input_server/protocol.py`。两侧测试共同读取
`Tests/VoiceInputCoreTests/Fixtures/asr_v1.json`；任何字段名、枚举、UUID 表示或消息结构变化都必须
同时更新实现、共享 fixture 和两端契约测试。客户端会在连接前执行与服务端一致的配置上限校验。

## 当前现网兼容入口

标准 v1 仍是目标协议。迁移期间，当客户端唯一配置 URL 的路径严格等于
`/api/voice-input/stream` 时，使用已经部署的 VoiceInk 兼容格式：

- 开始：`type=start`、`task_id`、16 kHz、单声道、`pcm_s16le`、语言和 partial 间隔。
- 音频：二进制 PCM16 分片。
- 结束：`{"type":"end"}`。
- 服务端：`ready/partial/final/error`，可在顶层或 `result/data.text` 返回文字。

兼容入口仍只使用同一个设置 URL，不代表自动探测或故障切换；`task_id` 若由服务端返回必须与
本次会话一致。该格式由 App 侧 codec 单元测试覆盖，不改变 v1 共享 fixture。
