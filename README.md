# AI语音输入法

`ai-voice-input` 是一个面向 macOS、iPhone 与 Android 的独立 AI 语音输入项目：用户可按住说话，
也可按一下开始、再按一下结束；系统实时识别并整理语言，结束后把文字快速插入当前应用。

核心目标：低延迟、低成本、隐私优先、跨应用可用。输入使用语音，输出使用文字；默认不做全双工对话、TTS 或 OpenAI Realtime。

项目架构见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 当前状态

- macOS 原生菜单栏应用已经落地，包含可自行录制的全局快捷键（含单独左/右 Command）、长按/切换两种录音触发方式、麦克风采集、流式识别、实时悬浮文字、按应用规则、个人词典和光标插入。单 Command 会区分独立手势与 `⌘C`、`⌘V`、`⌘Tab` 等正常组合操作。
- iOS 17+ MVP 已建立源码与独立 XcodeGen 工程：主应用负责麦克风、流式 ASR、AI 整理与 Keychain Token；键盘扩展只通过 App Group 消费 10 分钟内的一次性 final 并调用 `textDocumentProxy.insertText`。真机 App Group 运行与发布仍需 Apple Developer Team 签名。
- Android 8.0+ 测试版已经落地为原生系统输入法：键盘内支持长按/切换录音、三种模式、实时 partial、final 直插、热词/个人词典/风格、密码框禁用和插入失败内存恢复；Token 与个人资料分别使用 Android Keystore 加密。
- ASR WebSocket v1 协议、Swift/Python 共享契约、支持停机排空的 Python 参考适配服务和 macOS/iOS CI 已建立。
- 设置整体 AES-GCM 加密，密钥和服务令牌分账户保存在 Keychain；诊断与插入失败恢复均不持久化转写正文。
- macOS 开发版可通过 `make mac-local-install` 安装。
- 客户端只连接一个可配置的 ASR 地址；N150、备用节点、离线识别和自动故障切换均不在当前范围。
- macOS 客户端支持标准 v1 ASR 协议与 `/api/voice-input/stream` 兼容协议。
- macOS 识别失败时可按 `Esc` 隐藏“无法完成”悬浮状态框；错误状态和本次运行内可恢复的文字仍保留在菜单栏。
- 忠实听写只返回 ASR 结果。智能整理和指令模式将识别结果提交给配置的文字整理服务。智能整理也会提交用户设置的热词作为候选术语。原始音频和整份个人词典不会发送给整理服务。

## 架构

```text
macOS VoiceInput ── 私网/TLS ── 单一流式 ASR 服务
       │
       └── Accessibility / 受控粘贴 ── 当前应用光标
```

客户端与 ASR 之间的协议见 [docs/ASR_PROTOCOL.md](docs/ASR_PROTOCOL.md)。参考服务可使用
模拟后端验证完整链路，或适配 OpenAI-compatible `/audio/transcriptions` 接口。

## 开发

macOS 14+、Xcode 16+：

```bash
brew install xcodegen
make mac-project
make mac-test
```

iOS 17+ 模拟器：

```bash
make ios-project
make ios-test
```

iOS 架构、签名和系统限制见 [docs/IOS.md](docs/IOS.md)。

Android 8.0+、JDK 17+、Android SDK 36：

```bash
make android-test
make android-apk
# 已连接测试机时
make android-install
```

安装、启用输入法和隐私边界见 [docs/ANDROID.md](docs/ANDROID.md)。

协议服务（Python 3.12+）：

```bash
make server-bootstrap
make server-test
```

构建、签名和发布说明见 [docs/BUILDING.md](docs/BUILDING.md)。
