import SwiftUI
import VoiceInputCore

@main
struct VoiceInputIOSApp: App {
    @StateObject private var model = IOSAppModel()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                IOSContentView(model: model)
            }
        }
    }
}

private struct IOSContentView: View {
    @ObservedObject var model: IOSAppModel

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Label(model.state.title, systemImage: stateSymbol)
                        .font(.headline)
                        .foregroundStyle(stateColor)
                    Text(model.statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if model.state == .listening || model.state == .connecting {
                        ProgressView(value: Double(model.inputLevel))
                            .tint(.red)
                    }

                    if !model.partialTranscript.isEmpty {
                        Text(model.partialTranscript)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    }

                    if !model.finalTranscript.isEmpty {
                        Text(model.finalTranscript)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    }

                    controls
                }
                .padding(.vertical, 4)
            } header: {
                Text("语音输入")
            }

            Section("识别模式") {
                Picker("模式", selection: $model.mode) {
                    ForEach(InputMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(model.mode == .faithful
                     ? "忠实听写只返回 ASR 结果。"
                     : "智能整理和指令模式会在 ASR 后处理最终文字，不外发原始音频。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("ASR 连接") {
                TextField("wss://.../v1/asr/stream", text: $model.serverURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("语言", text: $model.language)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Bearer Token", text: $model.token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle("允许本机 / Tailscale 明文 ws://", isOn: $model.allowInsecurePrivateNetwork)
                Text("仅在 iPhone 已连接受信任的 Tailscale 私网时开启。客户端仍会拒绝公网和普通局域网 ws:// 地址。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("保存设置") { model.saveSettings() }
            }
            .disabled(model.state.isActive)

            Section("启用键盘") {
                Text("1. 打开系统设置 → 通用 → 键盘 → 键盘。")
                Text("2. 添加“语音输入”，并允许完全访问。")
                Text("3. 在本应用录音完成后回到原应用，切换键盘并插入最新文字。")
                Text("键盘扩展本身不使用麦克风、不连网；“完全访问”只用于读取 App Group 中一次性的最终文字。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("系统限制") {
                Text("iOS 第三方键盘无法在安全输入框中工作，部分应用也会强制切回系统键盘。这是 iOS 平台限制。")
            }
        }
        .navigationTitle("语音输入法")
        .onChange(of: model.mode) { _, _ in model.saveSettings() }
        .onChange(of: model.allowInsecurePrivateNetwork) { _, _ in model.saveSettings() }
    }

    @ViewBuilder
    private var controls: some View {
        switch model.state {
        case .requestingPermission, .connecting, .listening:
            HStack {
                Button("取消", role: .cancel) {
                    Task { await model.cancelRecording() }
                }
                Spacer()
                Button("停止并生成文字") {
                    Task { await model.stopRecording() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.state == .requestingPermission)
            }
        case .finalizing:
            HStack {
                ProgressView()
                Text("正在处理…")
                Spacer()
                Button("取消", role: .cancel) {
                    Task { await model.cancelRecording() }
                }
            }
        case .completed:
            HStack {
                Button("清除待插入文字", role: .destructive) {
                    model.clearPreparedTranscript()
                }
                Spacer()
                Button("再录一次") {
                    Task { await model.startRecording() }
                }
                .buttonStyle(.borderedProminent)
            }
        case .idle, .failed:
            Button {
                Task { await model.startRecording() }
            } label: {
                Label("开始录音", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var stateSymbol: String {
        switch model.state {
        case .idle: "mic"
        case .requestingPermission, .connecting: "ellipsis.circle"
        case .listening: "waveform"
        case .finalizing: "wand.and.stars"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var stateColor: Color {
        switch model.state {
        case .idle: .primary
        case .requestingPermission, .connecting, .finalizing: .orange
        case .listening: .red
        case .completed: .green
        case .failed: .yellow
        }
    }
}
