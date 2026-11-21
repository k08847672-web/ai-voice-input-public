# 构建、签名与发布

## 开发构建

要求 macOS 14+、Xcode 16+、XcodeGen 2.42+。CI 固定使用 XcodeGen 2.42.0 发布包及其
SHA-256，GitHub Actions 也固定到提交摘要，避免浮动标签改变构建结果。

```bash
brew install xcodegen
make mac-project
open VoiceInput.xcodeproj
```

在 Xcode 中选择 `VoiceInput` scheme。首次启动后按设置页提示授予麦克风、辅助功能和输入监控
权限。开发时可运行 `make server-run`，把客户端地址设为
`ws://127.0.0.1:8765/v1/asr/stream` 并显式打开本机非 TLS 调试。

## 自动测试

```bash
make mac-test
make server-test
```

CI 在 macOS runner 上重新生成工程并执行 `swift test` 与 `xcodebuild test`；Linux runner 执行
Python 协议测试、Ruff、构建固定摘要的服务镜像、启动健康检查和 `git diff --check`。生成的
`.xcodeproj` 不提交，`project.yml` 是工程源。

iOS 使用独立的 `ios/project.yml`：

```bash
make ios-project
make ios-test
```

iOS CI 生成主应用、键盘扩展和两个共用 framework，然后在最新可用的 iPhone
Simulator 上运行 App Group 一次性存储测试。真机构建需要 Apple Developer Team 和已注册的
Bundle ID/App Group；详见 [IOS.md](IOS.md)。

macOS 门禁通过后还会上传 `VoiceInput-macos-arm64-unsigned` 测试构建。该产物只用于本机
兼容性测试；它不是 Developer ID 签名或已公证的发布包。不要再直接对它执行 ad-hoc 签名，
应使用下述持久本机签名流程。

## 持久本机签名与安装

这条通道用于当前开发 Mac，目标是让辅助功能、输入监控和麦克风权限在应用升级后保持。它会在
默认用户钥匙串中创建一个有效期 10 年、仅限本机信任的 `VoiceInput Local Signing` 身份；私钥
不可导出，只授权 Apple 的 `codesign`/`security` 工具。首次执行：

```bash
make mac-local-signing-setup
```

把 CI 下载并解压后的 arm64 App 放在 `dist/VoiceInput.app`，然后执行：

```bash
make mac-local-install
```

安装脚本会复制源 App、从内到外重新签名、保留 Hardened Runtime 和 Audio Input entitlement、
拒绝仍绑定单次代码哈希的 ad-hoc designated requirement，严格验签后固定安装到
`/Applications/VoiceInput.app` 并启动。已有固定路径版本会先移动到 owner-only 的
`~/Library/Application Support/AI Voice Input/App Backups/`，安装失败则恢复。

本机自签证书没有 Apple Team ID，因此这条通道单独使用 `VoiceInputLocal.entitlements` 关闭
Hardened Runtime 的 Library Validation，允许加载由同一证书签名的 `VoiceInputCore.framework`。
该例外仅限本机测试；Developer ID 归档继续使用 `VoiceInput.entitlements`，明确禁止关闭 Library
Validation。

从 ad-hoc 测试版第一次迁移到持久身份时，macOS 会要求最后授权一次；以后只要不删除本机签名
证书、不改变 Bundle ID `com.aivoiceinput.mac`、不改安装路径，并始终用 `make mac-local-install`
更新，代码 designated requirement 会保持稳定，正常升级不应重复授权。这个本机自签身份不能
用于发给其他用户，也不能通过 Gatekeeper；外部发布必须走下述 Developer ID 流程。

## Developer ID 发布

准备 Apple Developer Team、`Developer ID Application` 证书和 notarytool 钥匙串配置文件。
敏感内容不得写进仓库。运行：

```bash
VOICE_INPUT_TEAM_ID=ABCDE12345 \
VOICE_INPUT_VERSION=1.0.0 \
VOICE_INPUT_BUILD_NUMBER=1 \
VOICE_INPUT_BUNDLE_ID=com.example.voiceinput \
make mac-archive
VOICE_INPUT_NOTARY_PROFILE=voice-input-notary make mac-notarize
```

归档脚本使用 `Developer ID Application`、安全时间戳、Hardened Runtime 和 Audio Input entitlement，
输出 `dist/VoiceInput.xcarchive` 与待公证的 `dist/VoiceInput.zip`。公证脚本上传、等待结果、staple、
执行 codesign/Gatekeeper 复核，并重新打包最终的 `dist/VoiceInput-notarized.zip`；发布时不能误用
公证前的 zip。发布前必须在一台干净的 Mac 上验证首次权限流程、快捷键、TextEdit、浏览器、IDE
和办公软件中的插入行为。

## 外部发布前门禁

- 检查由 `scripts/generate_app_icons.py` 生成的原创 AppIcon；若替换品牌图标，确认没有复用 KeyVox 或其他产品的资产。
- 设置唯一 Bundle ID、Team ID、版本号和更新分发渠道。
- 使用真实 ASR 执行验收矩阵，确认 TLS 证书、令牌轮换和限流。
- `codesign --verify --deep --strict`、`spctl --assess --type execute` 与公证均成功。
- 隐私说明准确描述麦克风、热词、词典和源应用 Bundle ID 的传输范围。
