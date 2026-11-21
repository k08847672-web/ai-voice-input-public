# Android 测试版

Android 客户端是独立的原生系统输入法，最低支持 Android 8.0（API 26）。测试 APK 可以直接安装，
不需要 Google Play 开发者账号，也没有 iOS 免费签名的 7 天期限。

## 当前能力

- 键盘内按住说话，或按一下开始、再按一下结束。
- 忠实听写、智能整理和指令三种模式；模式可在键盘上直接切换。
- 16 kHz 单声道 PCM16 流式录音，实时显示 partial，final 返回后写入当前输入框。
- 设置热词、`口述=写法` 个人词典和表达风格。热词会发送给私网 ASR，智能整理时还会作为候选术语提交给文字整理服务；不要填入敏感词，个人词典不会整体外发。
- Bearer Token 与热词/词典/风格使用不同的 Android Keystore AES-GCM 密钥加密；个人资料解密失败时禁止覆盖，只有设置页二次确认后才能清除并重建密钥。
- 不保存录音、转写历史或剪贴板副本。
- 密码输入框禁用录音；原输入目标失效时 final 只在键盘内存中保留并允许手动重试一次。

## 安装与首次启用

测试包位于 `dist/VoiceInput-android-debug.apk`。连接设备并打开 USB 调试后：

```bash
make android-install
```

也可以把 APK 发送到设备后手动安装。首次启动“AI语音输入法”应用：

1. 点击“允许麦克风”，在系统对话框中确认。
2. 点击“启用输入法”，在 Android 设置中开启“AI语音输入”。第三方键盘能处理输入内容，系统会显示相应安全提示，应由设备用户本人确认。
3. 回到应用，点击“切换输入法”，选择“AI语音输入”。
4. 填写项目专用 ASR Bearer Token。默认地址为 `ws://100.91.11.111:19001/v1/asr/stream`；
   使用它时勾选“允许 localhost/Tailscale 私网使用 ws://”。升级时仅迁移精确匹配的旧 mini 地址。
5. 确认手机已经加入获准的 Tailscale 网络，然后在普通文本框中开始测试。

不要在密码、验证码、支付或其他敏感字段中使用第三方键盘。应用会识别常见 Android 密码字段并
关闭录音，但不能替代用户对宿主应用和系统安全边界的判断。

## 本机构建与验证

### 输入法底部安全区（2026-09-06）

PJZ110 / Android 16 的系统输入法隐藏键、切换键和手势条会覆盖键盘窗口底部。
键盘根布局根据系统 navigationBars 与 mandatorySystemGestures 的实际 inset 增加底部留白，
不使用整块 IME inset，不硬编码某一手机的高度；重复显示按原始边距重新计算，避免逐次累加。
整排删除、说话和换行键均保持在该安全区上方。这里只修改布局，不调整录音、ASR、模式或个人资料。

0.1.1 / 2 已保数据覆盖安装并在 PJZ110 竖屏手势导航下确认：底部三键与系统隐藏/切换键、
手势条分离，默认输入法不变，未修改或发送宿主草稿。9 项 JVM 测试、Debug lint 和构建通过。
设备 APK SHA-256 与 `dist/VoiceInput-android-0.1.1-debug.apk` 一致：
`c30b309f86b07cf475f842d5546ee2354f0e860d39248d7effd16607893c1fc0`。
同证书旧版 `dist/VoiceInput-android-0.1.0-debug.apk` 保留。未验收横屏/三键导航；
按用户要求，录音和 ASR 对照暂缓，不以本次布局验证宣称识别质量已改善。

### 构建命令

需要 JDK 17+ 和 Android SDK 36；macOS Homebrew 的默认路径已写入 Makefile，也可以通过现有
`JAVA_HOME` 和 `ANDROID_HOME` 覆盖：

```bash
make android-test
make android-apk
```

`android-test` 运行 JVM 单元测试和 Android lint；`android-apk` 生成 debug 签名测试包并复制到
`dist/VoiceInput-android-debug.apk`。debug 签名只用于测试，正式上架前必须建立受控的 release
keystore、密钥备份和独立发布流程。

0.1.2 / 3 将默认和精确匹配的旧 mini 地址迁移到 `100.91.11.111:19001`；覆盖安装保留
Android Keystore 中的 Token 和用户配置，不会替用户开启 Tailscale 或授予权限。

## 尚未完成的真机验收

- 麦克风授权后的真实音频采集与 180 秒自动停止。
- Q25 → Tailscale → Mac mini `100.91.11.111:19001` → 办公室 ASR `100.100.97.120:8765` 的完整链路。
- 忠实听写、智能整理、指令三种模式的文字质量和延迟。
- 常用应用、换行/删除、目标切换、密码输入框和插入失败恢复矩阵。
- 长时间稳定性、电量、网络中断和进程重启测试。
