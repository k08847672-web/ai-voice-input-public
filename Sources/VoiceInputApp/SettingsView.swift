import AppKit
import SwiftUI
import VoiceInputCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store: SettingsStore

    init(model: AppModel) {
        self.model = model
        store = model.settingsStore
    }

    var body: some View {
        TabView {
            GeneralSettingsView(model: model, store: store)
                .tabItem { Label("通用", systemImage: "gearshape") }
            RecognitionSettingsView(model: model, store: store)
                .tabItem { Label("识别", systemImage: "waveform") }
            DictionarySettingsView(model: model, store: store)
                .tabItem { Label("词典", systemImage: "character.book.closed") }
            AppProfilesSettingsView(store: store)
                .tabItem { Label("应用", systemImage: "square.grid.2x2") }
            PrivacySettingsView(model: model)
                .tabItem { Label("隐私与诊断", systemImage: "hand.raised") }
        }
        .padding(18)
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SettingsStore
    @State private var showingSettingsResetConfirmation = false

    var body: some View {
        Form {
            Section("权限") {
                PermissionRow(
                    name: "麦克风",
                    granted: model.permissionSnapshot.microphone,
                    action: { Task { await model.requestMicrophonePermission() } }
                )
                PermissionRow(
                    name: "辅助功能",
                    granted: model.permissionSnapshot.accessibility,
                    action: model.requestAccessibilityPermission
                )
                PermissionRow(
                    name: "输入监控",
                    granted: model.permissionSnapshot.inputMonitoring,
                    action: model.requestInputMonitoringPermission
                )
                Button("刷新权限状态") { model.refreshPermissions() }
            }
            Section("快捷键与录音") {
                MicrophoneSettingsView(
                    store: store, test: model.microphoneTest,
                    devices: model.inputDevices, canTest: model.canConfigureHotKey
                )
                Text("只用于本App，下次录音生效。设备未连接时暂用系统默认，重连后恢复所选设备。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("快捷键")
                    Spacer()
                    HotKeyRecorderView(
                        descriptor: $store.settings.hotKey,
                        isEnabled: model.canConfigureHotKey,
                        onRecordingChanged: { isRecording in
                            if isRecording {
                                model.suspendHotKeyForRecording()
                            } else {
                                model.configureHotKey()
                            }
                        }
                    )
                    .frame(width: 250)
                }
                Picker("触发方式", selection: $store.settings.hotKey.activationMode) {
                    ForEach(HotKeyActivationMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Text("点击快捷键框后直接按新组合键；按 Esc 取消。普通按键需搭配 ⌃、⌥ 或 ⌘；左/右 Command 与 F1–F20 可单独使用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(hotKeyHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("行为") {
                Toggle("显示实时悬浮文字", isOn: $store.settings.showOverlay)
                Toggle("播放开始和完成提示音", isOn: $store.settings.playSounds)
                Toggle("登录时启动", isOn: $store.settings.launchAtLogin)
                    .onChange(of: store.settings.launchAtLogin) { _, _ in store.applyLaunchAtLogin() }
            }
            if let error = store.persistenceError {
                Text(error).foregroundStyle(.red)
            }
            if store.requiresSettingsReset {
                Button("重置无法读取的本地设置", role: .destructive) {
                    showingSettingsResetConfirmation = true
                }
                .confirmationDialog(
                    "确认重置本地设置？",
                    isPresented: $showingSettingsResetConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("重置设置", role: .destructive) { store.resetUnreadableSettings() }
                } message: {
                    Text("这会删除无法解密的设置文件和加密密钥；ASR 服务令牌将继续保留。")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshInputDevices() }
    }

    private var hotKeyHelpText: String {
        let shortcut = store.settings.hotKey.displayName
        return switch store.settings.hotKey.activationMode {
        case .pressAndHold:
            "按住 \(shortcut) 开始录音，松开后整理并插入。"
        case .toggle:
            "按一下 \(shortcut) 开始录音，再按一下结束并插入。"
        }
    }
}

private struct PermissionRow: View {
    let name: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Label(name, systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? .green : .orange)
            Spacer()
            if !granted { Button("授权", action: action) }
        }
    }
}

private struct MicrophoneSettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var test: MicrophoneTestController
    let devices: [AudioInputDevice]
    let canTest: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("麦克风", selection: $store.microphoneDeviceUID) {
                    Text("跟随系统默认").tag(nil as String?)
                    ForEach(devices) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                    if let uid = store.microphoneDeviceUID,
                       !devices.contains(where: { $0.uid == uid }) {
                        Text("所选麦克风未连接（暂用系统默认）").tag(Optional(uid))
                    }
                }
                Button(test.isRecording ? "停止录音" : "测试麦克风") {
                    if test.isRecording {
                        test.stopRecording()
                    } else {
                        let uid = store.microphoneDeviceUID
                        Task { await test.start(inputDeviceUID: uid) }
                    }
                }
                .disabled(!canTest || test.isPreparing)
            }
            Text("测试录音最多5秒，可提前停止并回放；音频仅在本机内存中，不上传、不保存。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if test.isPreparing { Text("正在准备麦克风…").font(.caption) }
            if test.isRecording {
                HStack {
                    Text("输入音量")
                    ProgressView(value: Double(test.level)).frame(maxWidth: .infinity)
                    Text("\(test.duration, specifier: "%.1f") / 5秒").monospacedDigit()
                }
                .font(.caption)
            }
            if test.hasSample && !test.isRecording {
                HStack {
                    Text("已录制 \(test.duration, specifier: "%.1f") 秒").font(.caption)
                    Button(test.isPlaying ? "停止回放" : "回放") {
                        if test.isPlaying { test.stopPlayback() } else { test.play() }
                    }
                    .disabled(!canTest)
                    Button("取消测试") { test.cancel() }
                }
            }
            if let error = test.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .onDisappear { test.cancel() }
    }
}

private struct RecognitionSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("单一 ASR 服务") {
                TextField("WebSocket 地址", text: $store.settings.serverURL)
                    .textFieldStyle(.roundedBorder)
                SecureField("Bearer Token（保存在钥匙串）", text: $store.token)
                    .textFieldStyle(.roundedBorder)
                Picker("语言", selection: $store.settings.language) {
                    Text("简体中文").tag("zh-CN")
                    Text("英语").tag("en-US")
                    Text("自动检测").tag("auto")
                }
                Toggle(
                    "允许本机或 Tailscale 私网 ws://",
                    isOn: $store.settings.allowInsecurePrivateNetwork
                )
                HStack {
                    Button("测试连接") { Task { await model.testServer() } }
                    if let message = model.serverTestMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("公网地址强制使用 wss://；显式开启后仅额外允许 localhost 和 Tailscale 100.64.0.0/10。客户端不会自动切换识别节点。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("默认模式") {
                Picker("模式", selection: $store.settings.defaultMode) {
                    ForEach(InputMode.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("热词") {
                TokenListEditor(values: $store.settings.hotwords, placeholder: "添加人名、项目名或术语")
                Text("热词发送给私网 ASR；智能整理时也会作为候选术语交给文字整理服务。只填愿意外发的非敏感词；是否影响原始识别取决于 ASR 实现。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct TokenListEditor: View {
    @Binding var values: [String]
    let placeholder: String
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(placeholder, text: $draft)
                    .onSubmit(add)
                Button("添加", action: add).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            FlowLayout(spacing: 6) {
                ForEach(values, id: \.self) { value in
                    HStack(spacing: 4) {
                        Text(value)
                        Button { values.removeAll { $0 == value } } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
                }
            }
        }
    }

    private func add() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !values.contains(value) else { return }
        values.append(value)
        draft = ""
    }
}

private struct DictionarySettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("个人词典").font(.headline)
            Text("点录音说出词，再点停止；原始 ASR 结果填入读音，写法由你填写。也可直接编辑读音。")
                .font(.caption).foregroundStyle(.secondary)
            Table($store.settings.dictionary) {
                TableColumn("读音") { $entry in TextField("例如：扣得克斯", text: $entry.spoken) }
                TableColumn("写法") { $entry in TextField("例如：Codex", text: $entry.written) }
                TableColumn("语音") { $entry in
                    Button {
                        Task {
                            if model.dictionaryRecordingID == entry.id {
                                await model.endInput()
                            } else {
                                await model.beginDictionaryPronunciation(for: entry.id)
                            }
                        }
                    } label: {
                        Image(systemName: model.dictionaryRecordingID == entry.id ? "stop.circle.fill" : "mic.circle")
                    }
                    .help(model.dictionaryRecordingID == entry.id ? "停止并识别读音" : "录音填入读音")
                    .disabled(
                        model.state == .finalizing || model.state == .inserting ||
                            (model.dictionaryRecordingID != nil && model.dictionaryRecordingID != entry.id) ||
                            (model.dictionaryRecordingID == nil && !model.canStartDictionaryPronunciation)
                    )
                }
                .width(48)
                TableColumn("") { $entry in
                    Button { store.settings.dictionary.removeAll { $0.id == entry.id } } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .disabled(model.dictionaryRecordingID == entry.id)
                }
                .width(36)
            }
            if let message = model.dictionaryRecordingMessage {
                HStack {
                    Text(message)
                    if model.dictionaryRecordingID != nil {
                        Button("取消") { Task { await model.cancelInput() } }
                    }
                }
                .font(.caption)
            }
            if model.dictionaryRecordingID != nil, !model.partialTranscript.isEmpty {
                Text("实时识别：\(model.partialTranscript)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text(model.dictionarySyncMessage)
                    .font(.caption).foregroundStyle(.secondary)
                Button("立即同步") { Task { await model.syncDictionary() } }
                    .controlSize(.small)
            }
            HStack {
                Button("添加词条") {
                    store.settings.dictionary.append(DictionaryEntry(spoken: "", written: ""))
                }
                Spacer()
                Text("\(store.settings.dictionary.count) 个词条").foregroundStyle(.secondary)
            }
        }
    }
}

private struct AppProfilesSettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("按应用规则").font(.headline)
            Text("Bundle ID 完全匹配时覆盖默认模式，并把风格要求交给识别服务。")
                .font(.caption).foregroundStyle(.secondary)
            Table($store.settings.appProfiles) {
                TableColumn("应用名称") { $profile in TextField("应用", text: $profile.name) }
                TableColumn("Bundle ID") { $profile in TextField("com.example.app", text: $profile.bundleIdentifier) }
                TableColumn("模式") { $profile in
                    Picker("", selection: $profile.mode) {
                        ForEach(InputMode.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                }
                TableColumn("风格") { $profile in TextField("例如：邮件，正式简洁", text: $profile.style) }
                TableColumn("") { $profile in
                    Button { store.settings.appProfiles.removeAll { $0.id == profile.id } } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                }
                .width(36)
            }
            Button("添加规则") {
                store.settings.appProfiles.append(
                    AppProfile(bundleIdentifier: "", name: "", mode: store.settings.defaultMode)
                )
            }
        }
    }
}

private struct PrivacySettingsView: View {
    @ObservedObject var model: AppModel
    @State private var showingClearPersonalizationConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("隐私边界") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("原始音频只在内存中分片，不写入磁盘", systemImage: "checkmark.shield")
                    Label("诊断记录不包含音频、识别文本或访问令牌", systemImage: "checkmark.shield")
                    Label("安全输入框中拒绝插入文字", systemImage: "checkmark.shield")
                    Label("服务端令牌保存在 macOS 钥匙串", systemImage: "checkmark.shield")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            HStack {
                Text("本次运行诊断：\(model.diagnostics.records.count) 条")
                Spacer()
                Button("导出") { model.diagnostics.export() }
                Button("清除") { model.diagnostics.clear() }
            }
            Button("清除热词、个人词典和应用规则", role: .destructive) {
                showingClearPersonalizationConfirmation = true
            }
            .confirmationDialog(
                "确认清除个性化设置？",
                isPresented: $showingClearPersonalizationConfirmation,
                titleVisibility: .visible
            ) {
                Button("全部清除", role: .destructive) {
                    model.settingsStore.clearPersonalization()
                }
            } message: {
                Text("该操作不可撤销；ASR 服务地址、令牌和通用设置不会改变。")
            }
            List(model.diagnostics.records.suffix(100).reversed()) { record in
                HStack {
                    Text(record.timestamp, style: .time).foregroundStyle(.secondary)
                    Text(record.event)
                    Spacer()
                    Text(record.level.rawValue).foregroundStyle(record.level == .error ? .red : .secondary)
                }
                .font(.caption)
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + rowHeight), points)
    }
}
