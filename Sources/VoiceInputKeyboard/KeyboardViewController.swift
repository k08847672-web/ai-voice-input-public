import Combine
import SwiftUI
import UIKit
import VoiceInputMobileShared

@MainActor
final class KeyboardModel: ObservableObject {
    @Published private(set) var preview = ""
    @Published private(set) var status = "先在“语音输入法”主应用中完成录音。"
    @Published private(set) var canInsert = false

    private let store: SharedTranscriptStore?

    init(store: SharedTranscriptStore? = SharedTranscriptStore()) {
        self.store = store
    }

    func refresh(hasFullAccess: Bool) {
        guard hasFullAccess else {
            preview = ""
            canInsert = false
            status = "需在系统设置中允许完全访问，才能读取主应用的一次性结果。"
            return
        }
        guard let pending = store?.peek() else {
            preview = ""
            canInsert = false
            status = "没有待插入文字，或结果已超过 10 分钟。"
            return
        }
        preview = pending.text
        canInsert = true
        status = "点击后只插入一次，成功取出后立即删除。"
    }

    func consume(hasFullAccess: Bool) -> String? {
        guard hasFullAccess else {
            refresh(hasFullAccess: false)
            return nil
        }
        guard let text = store?.consume() else {
            refresh(hasFullAccess: true)
            return nil
        }
        preview = ""
        canInsert = false
        status = "已插入，一次性结果已删除。"
        return text
    }
}

final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardModel()
    private var hostingController: UIHostingController<KeyboardRootView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        let rootView = KeyboardRootView(
            model: model,
            onInsert: { [weak self] in self?.insertLatestTranscript() },
            onDelete: { [weak self] in self?.textDocumentProxy.deleteBackward() },
            onSpace: { [weak self] in self?.textDocumentProxy.insertText(" ") },
            onReturn: { [weak self] in self?.textDocumentProxy.insertText("\n") },
            onNextKeyboard: { [weak self] in self?.advanceToNextInputMode() },
            needsNextKeyboardKey: { [weak self] in self?.needsInputModeSwitchKey ?? true }
        )
        let hostingController = UIHostingController(rootView: rootView)
        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        hostingController.view.backgroundColor = .clear
        view.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hostingController.didMove(toParent: self)
        self.hostingController = hostingController
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.refresh(hasFullAccess: hasFullAccess)
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        model.refresh(hasFullAccess: hasFullAccess)
    }

    private func insertLatestTranscript() {
        guard let text = model.consume(hasFullAccess: hasFullAccess) else { return }
        textDocumentProxy.insertText(text)
    }
}

private struct KeyboardRootView: View {
    @ObservedObject var model: KeyboardModel
    let onInsert: () -> Void
    let onDelete: () -> Void
    let onSpace: () -> Void
    let onReturn: () -> Void
    let onNextKeyboard: () -> Void
    let needsNextKeyboardKey: () -> Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.title2)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("语音输入")
                        .font(.headline)
                    Text(model.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }

            if !model.preview.isEmpty {
                Text(model.preview)
                    .font(.callout)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
            }

            Button(action: onInsert) {
                Label("插入最新文字", systemImage: "text.badge.checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canInsert)

            HStack(spacing: 8) {
                if needsNextKeyboardKey() {
                    keyButton(systemImage: "globe", action: onNextKeyboard)
                }
                keyButton(systemImage: "delete.left", action: onDelete)
                Button("空格", action: onSpace)
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.bordered)
                keyButton(systemImage: "return", action: onReturn)
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private func keyButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(minWidth: 36, minHeight: 24)
        }
        .buttonStyle(.bordered)
    }
}
