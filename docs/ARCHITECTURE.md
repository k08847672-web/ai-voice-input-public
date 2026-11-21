# 客户端架构

## 产品边界

当前产品实现 macOS 14+ 的全局快捷键语音输入，支持“按住说话、松开插入”和
“按一下开始、再按一下结束”两种触发方式。客户端只连接设置中的一个 ASR
WebSocket 地址，不探测或切换其他节点，不提供离线识别，不把音频保存到磁盘。

当前部署拓扑如下。只有 `smart` 和 `command` 模式会在 ASR final 后调用整理器；
发往美国反代的是 final 文字，不是原始音频。

```text
macOS VoiceInput
  └─ PCM / 标准 v1 WebSocket ─> Mac mini 100.91.11.111:19001
                                  ├─ PCM / VoiceInk WebSocket ─> 办公室 ASR 100.100.97.120:8765
                                  └─ final 文字 / HTTPS ─> 美国服务器 Tailscale 100.77.170.19（TLS 身份：uin.doitio.com）
```

```text
CGEventTap ── press ──> AppModel ──> AVAudioEngine ── PCM16 frames ──> WebSocketASRClient
    │                      │                                            │
    └── release ───────────┴──────────────────── stop ──────────────────┘
                           │                                            │
                           │<──────── ready / partial / final ──────────┘
                           │
                           ├── OverlayWindowController（实时文本）
                           └── TextInsertionService ──> 当前光标
```

## 模块职责

- `VoiceInputCore`：稳定的网络协议、设置模型、输入模式和确定性词典替换。它不持有 UI 或凭据。
- `RecognitionSessionState`：纯 Swift 会话状态机，验证 ready/partial/final 的顺序，并明确处理快速松开时仍在途的 ready/partial。
- `AppModel`：主状态机；每次按住动作只允许一个会话，以会话代际隔离迟到的异步回调，负责启动、收尾、超时和错误显示。会话开始前捕获输入目标和模式，结束后仍向该目标插入，避免录音悬浮窗或设置界面抢走焦点。
- `AudioCaptureService`：使用 `AVAudioEngine` 采集并转换为 16 kHz、单声道、PCM16 小端数据。
- `WebSocketASRClient`：建立单一会话，隔离重入的连接生命周期，串行发送音频，验证服务端会话 ID。
  默认使用标准 v1 编解码；当唯一设置 URL 的路径严格等于 `/api/voice-input/stream` 时，使用现网
  VoiceInk `start → PCM → end` 兼容编解码。协议兼容不会增加第二地址、探测节点或故障切换。
  当前安装版使用 Mac mini 的标准 v1 适配入口；`DeployedServerMigration` 只把精确匹配的旧
  `ws://100.86.28.63:19000/api/voice-input/stream` 或 `ws://100.86.28.63:19001/v1/asr/stream` 设置
  迁移到 `ws://100.91.11.111:19001/v1/asr/stream`，
  其他自定义地址保持不变。
- `GlobalHotKeyMonitor`：只读 `CGEventTap` 监听按下和松开；新安装默认快捷键为
  `⌃⌥Space`，用户可在设置中直接录制任意组合。普通按键必须包含 Control、Option 或
  Command，F1–F20 以及左/右 Command 可单独使用，防止误把普通输入键注册为全局快捷键。
  单 Command 使用独立手势状态机：长按模式在持续按下 180 ms 后才开始录音，切换模式只在
  独立按下并松开时触发；期间出现其他按键、修饰键或鼠标点击会取消待触发动作，若录音已经
  开始则取消本次会话，因此 `⌘C`、`⌘V`、`⌘Tab` 和 Command+点击仍保留原系统行为。左、右
  Command 的物理按下状态分别跟踪，不依赖事件回调中可能滞后的全局 key state；同时按下两个
  Command 不会被误判为一次独立语音手势。
  识别失败时也监听 `Esc` 隐藏悬浮状态框，不清除菜单栏错误或内存中的可恢复文字。
- `HotKeyRecorderView`：录制期间暂停现有全局监听，`Esc` 取消，保存或取消后重新注册当前
  快捷键，避免在设置新组合时误启动语音会话。录制器等待 Command 松开后才保存单键手势；
  若期间继续按普通键，则仍按原逻辑保存完整组合键。重新注册时若 Command 尚未松开，全局
  监听会忽略这一次释放，避免保存设置后立刻误启动录音。
- `HotKeyInteractionPolicy`：把按下/松开事件和长按/切换配置解析为开始、结束、取消或忽略；
  finalizing 期间再次按下快捷键会取消卡住的会话，插入期间仍忽略重复输入。
- `TextInsertionService`：在录音开始前捕获目标进程与可编辑 Accessibility 元素，final 返回后优先写入该目标的 selected text；不支持时激活原目标并临时粘贴，在没有并发剪贴板修改时恢复原内容。目标失效或插入明确失败时，final 只在本次运行的内存中保留，用户可手动复制，不写历史。
- `SettingsStore`：整份设置用 AES-GCM 加密后原子写入 owner-only 的 Application Support 文件；随机加密密钥与 Bearer Token 分账户写入 Keychain。旧 `settings.json` 只做一次迁移，成功后立即删除明文。
- `DiagnosticsStore`：仅内存环形记录，字段采用 `mode/source_application/latency_ms/duration_ms/characters/code` 严格白名单；任意错误正文、音频、转写文本、提示词或令牌均不能进入记录。

## 会话状态机

```text
idle ── press ──> connecting ── ready ──> listening ── release ──> finalizing
 ^                    │                                               │
 │                    └─ release ─> finalizing_awaiting_ready ─ ready ┘
 │                                                                    │
 └──────── inserted <── inserting <────────────── final ──────────────┘
```

partial 只允许在 `listening` 或服务端已经 ready 的 `finalizing` 状态；final 只允许在 stop 之后。
任何重复或乱序事件都会作为协议错误终止会话。失败状态可在下一次按住时重试，取消从任意阶段回到 idle。
快速松开会先同步进入 finalizing，阻止重复 stop；即使此前的连接调用随后恢复，也只挂接事件流，绝不
晚启动麦克风。每个异步发送、超时和服务端事件都必须匹配当前会话代际。

客户端从进入 connecting 的瞬间开始计算 8 秒 ready 上限，从进入 finalizing 的瞬间开始计算
最终结果上限：忠实听写为 12 秒，智能整理和指令模式为 35 秒；因此 WebSocket 首包发送、音频
队列排空、stop/end 发送或整理器调用挂起都受超时覆盖。
单次录音上限为 180 秒。任意网络或服务错误都会结束本次会话并向用户显示，不会触发另一条识别链路。原始音频只存在于
`AVAudioPCMBuffer`、短期 `Data` 分片和 WebSocket 缓冲中。

## 输入安全

- 没有麦克风、输入监控或辅助功能权限时不开始会话。
- 单 Command 快捷键不会把正常 Command 组合键当作语音手势；延迟开始后的组合操作会立即
  取消本次语音会话，包含仍在权限或网络异步准备阶段的会话。
- 首次请求被拒后，设置页的独立权限按钮会打开对应的 macOS 隐私设置页；返回应用刷新后重新注册全局快捷键。
- 占位域名 `.invalid` 在发起网络连接前直接拒绝，并提示先配置有效 ASR 地址。
- 公网服务只接受 `wss://`；仅显式开启后允许 `ws://localhost` 和 Tailscale IPv4
  `100.64.0.0/10`，其他明文远程地址继续拒绝。Tailscale 例外依赖设备身份与私网边界。
- 开始录音前同时检查系统 Secure Event Input 与 Accessibility 安全输入框；命中时不采集、不发送音频，也不插入文字。
- 插入目标在开始录音前固定；识别期间焦点变化不会把 final 误写到悬浮窗、设置页或其他应用。
- 日志只保存事件名、延迟、字符数、错误码和源应用 Bundle ID；不保存用户说了什么。
- 热词、个人词典、应用规则和服务地址落盘前整体加密；无法解密时禁止自动覆盖，只有用户在确认框中明确重置才删除损坏数据与密钥。
- 隐私页可经二次确认一次清除热词、个人词典和应用规则；服务地址、令牌和通用设置不受影响。
- 不为语音命令执行系统操作；“指令模式”只产生文本，后续应用仍执行自己的审批。

## iOS 17+ MVP

```text
iPhone 主应用
  ├─ 麦克风 / PCM16 / WebSocket ─> 同一 ASR v1 服务
  ├─ final 文字 ─> SharedTranscriptStore ─> App Group（10 分钟逻辑过期）
  └─ Bearer Token ─> iOS Keychain（ThisDeviceOnly）

键盘扩展
  └─ consume final ─> textDocumentProxy.insertText ─> 当前输入框
```

- `VoiceInputCore`、`ASRWireCodec`、`WebSocketASRClient` 和 `AudioCaptureService` 与 macOS 复用同一份源码。
- 主应用是唯一的麦克风、网络和 Token 边界。键盘扩展不包含 ASR 运输源码，也不读取 Token。
- App Group 标识为 `group.com.aivoiceinput.shared`。final 经过去空白和长度校验后写入，10 分钟后不再可用，消费时先删除再返回，不建立转写历史。
- 键盘访问 App Group 需要用户在 iOS 设置中允许“完全访问”；本项目的扩展仍不连网，只读取一次性 final。
- 当前 ASR 入口是 Tailscale IPv4 上的 `ws://`。iOS Info.plist 放行 ATS 后，源码内的 `ASRURLValidator` 仍只允许用户显式开启的 localhost 和 `100.64.0.0/10`；外部发布前应换成 `wss://`。
- 安全输入框会让系统切回原生键盘，部分应用也可拒绝第三方键盘。主应用不尝试绕过这些系统限制。

## Android 8.0+ 测试版

```text
Android InputMethodService
  ├─ AudioRecord / 16 kHz PCM16 ─> 标准 v1 WebSocket ─> 同一 ASR 服务
  ├─ partial ─> 键盘内实时文字
  └─ final ─> 会话开始时捕获的 InputConnection.commitText
```

- `VoiceInputMethodService` 是系统输入法入口，在键盘可见时直接持有麦克风、ASR 会话和当前输入目标；不需要 iOS 的主应用/App Group 中转。
- 键盘支持“按住说话”和“按一下开始、再按一下结束”，并可即时切换忠实听写、智能整理和指令模式。录音上限 180 秒，ready 为 8 秒，faithful final 为 12 秒，smart/command final 为 35 秒。
- `PcmRecorder` 使用 `AudioRecord` 输出 16 kHz、单声道、PCM16 小端帧；`AsrSession` 只实现权威标准 v1 入口，不探测其他地址，也不自动故障切换。
- final 只提交给会话开始时捕获的应用/`InputConnection`。目标失效时文字仅保留在键盘进程内存中并提供一次重试，不写剪贴板或转写历史。
- 密码类型的 `EditorInfo` 主动禁用录音；切换输入目标或收起键盘会取消在途会话。公网必须使用 `wss://`，只有显式开启后才允许 localhost 或 Tailscale `100.64.0.0/10` 的 `ws://`。
- Bearer Token 与热词/词典/风格使用不同的 Android Keystore AES-GCM 密钥加密，解密失败时禁止覆盖，只有设置页二次确认才能清除并重建个人资料密钥；应用备份和设备迁移明确排除全部本地数据。服务地址、语言和模式保存在应用私有 `SharedPreferences`，任何个人资料都不会进入日志。
