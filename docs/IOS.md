# iOS 17+ MVP

## 交互边界

iOS 第三方键盘不能直接持有本项目需要的麦克风录音生命周期。当前 MVP 因此是：

1. 在“语音输入法”主应用中选择模式并录音。
2. 主应用把 16 kHz 单声道 PCM16 发往单一 ASR 入口，接收 partial 和 final。
3. 主应用把 final 发布到 App Group，不保存原始音频或转写历史。
4. 用户回到原应用，切换到“语音输入”键盘，点击“插入最新文字”。

当前 MVP 不声称从任意应用直接唤起麦克风，也不声称安全输入框可用。

## 模块

- `Sources/VoiceInputiOSApp/`：SwiftUI 主应用状态机、设置和 iOS Keychain Token。
- `Sources/VoiceInputKeyboard/`：`UIInputViewController` + SwiftUI 键盘界面，只插入文字。
- `Sources/VoiceInputMobileShared/`：主应用与键盘共用的一次性 final 存储。
- `ios/project.yml`：独立 iOS XcodeGen 工程源，不改变 macOS `project.yml`。

## 本地生成与模拟器测试

需要 Xcode 16+、XcodeGen 2.42+ 和一个已安装的 iPhone Simulator runtime：

```bash
make ios-project
make ios-test
open ios/VoiceInputIOS.xcodeproj
```

`make ios-test` 动态选择最新已安装 iOS runtime 中的可用 iPhone，不写死具体设备名。

## 真机签名

真机验收前必须在 Apple Developer 后台建立并配置：

- 主应用 Bundle ID `com.aivoiceinput.ios`。
- 键盘扩展 Bundle ID `com.aivoiceinput.ios.keyboard`。
- App Group `group.com.aivoiceinput.shared`，同时关联上述两个 App ID。
- 对应的 Development/Distribution provisioning profiles。

在 Xcode 中给 `VoiceInputIOS` 和 `VoiceInputKeyboard` 选择同一 Team。不得把证书、profile 或 Token 提交到仓库。

## 首次真机设置

1. 确保 iPhone 已登录 Tailscale 并可达当前 mini 标准 v1 入口 `100.91.11.111:19001`；
   该入口再通过 Tailscale 调用 ASR `100.100.97.120:8765`。
2. 在主应用中输入 Bearer Token。Token 只保存在 iOS Keychain，不进入 App Group。
3. 当使用 Tailscale `ws://` 地址时，显式打开“允许本机 / Tailscale 明文 ws://”。
4. 到系统设置 → 通用 → 键盘 → 键盘，添加“语音输入”并允许完全访问。

完全访问是 App Group 共享所需；当前键盘 target 没有 ASR 网络或麦克风源码。

## 发布前必做

- 将当前 Tailscale `ws://` 入口改为可验证证书的 `wss://`，然后收紧 iOS ATS 例外。
- 在真机上验证 App Group、完全访问、10 分钟过期和一次性消费。
- 分别在备忘录、Safari/Chrome、即时通讯、办公软件与安全输入框验证键盘行为。
- 用真实中文口述集重测忠实听写、智能整理和指令三种模式的延迟与保真度。
