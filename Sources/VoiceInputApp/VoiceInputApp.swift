import AppKit
import SwiftUI
import VoiceInputCore

@main
struct VoiceInputApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Label(model.state.label, systemImage: model.state.symbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
                .frame(minWidth: 680, minHeight: 520)
        }
    }
}

private struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: SettingsStore

    init(model: AppModel) {
        self.model = model
        settings = model.settingsStore
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: model.state.symbol)
                    .font(.title2)
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.state.label).font(.headline)
                    Text(hotKeyHelpText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if !model.partialTranscript.isEmpty {
                Text(model.partialTranscript)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }

            if model.recoverableTranscript != nil {
                Button {
                    model.copyRecoverableTranscript()
                } label: {
                    Label("复制临时保留的识别文字", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .help("文字只保留在本次运行的内存中，不会写入历史记录")
            }

            Picker("模式", selection: $settings.settings.defaultMode) {
                ForEach(InputMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                if model.state == .listening || model.state == .connecting {
                    Button("取消") { Task { await model.cancelInput() } }
                } else if model.state == .finalizing {
                    ProgressView().controlSize(.small)
                    Button("取消") { Task { await model.cancelInput() } }
                } else if model.state == .inserting {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                Button {
                    Task {
                        await model.shutdown()
                        NSApplication.shared.terminate(nil)
                    }
                } label: {
                    Image(systemName: "power")
                }
                .help("退出")
            }
        }
        .padding(16)
        .frame(width: 360)
        .task { model.start() }
    }

    private var statusColor: Color {
        switch model.state {
        case .idle: .primary
        case .connecting, .finalizing, .inserting: .orange
        case .listening: .red
        case .error: .yellow
        }
    }

    private var hotKeyLabel: String {
        settings.settings.hotKey.displayName
    }

    private var hotKeyHelpText: String {
        switch settings.settings.hotKey.activationMode {
        case .pressAndHold: "按住 \(hotKeyLabel) 讲话，松开插入"
        case .toggle: "按一下 \(hotKeyLabel) 开始，再按一下结束"
        }
    }
}
