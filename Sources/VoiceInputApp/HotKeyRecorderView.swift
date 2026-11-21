import AppKit
import SwiftUI
import VoiceInputCore

struct HotKeyRecorderView: NSViewRepresentable {
    @Binding var descriptor: HotKeyDescriptor
    let isEnabled: Bool
    let onRecordingChanged: (Bool) -> Void

    func makeNSView(context: Context) -> HotKeyRecorderButton {
        let button = HotKeyRecorderButton()
        configure(button)
        return button
    }

    func updateNSView(_ nsView: HotKeyRecorderButton, context: Context) {
        configure(nsView)
    }

    static func dismantleNSView(_ nsView: HotKeyRecorderButton, coordinator: ()) {
        nsView.cancelRecording()
    }

    private func configure(_ button: HotKeyRecorderButton) {
        button.descriptor = descriptor
        button.isEnabled = isEnabled
        let binding = $descriptor
        button.onRecorded = { newDescriptor in
            binding.wrappedValue = newDescriptor
        }
        button.onRecordingChanged = onRecordingChanged
    }
}

@MainActor
final class HotKeyRecorderButton: NSButton {
    var descriptor: HotKeyDescriptor = .default {
        didSet {
            if !isRecording { title = descriptor.displayName }
        }
    }
    var onRecorded: ((HotKeyDescriptor) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?

    private var eventMonitor: Any?
    private var isRecording = false
    private var commandRecorderGesture = ModifierOnlyHotKeyRecorderGesture()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
        title = descriptor.displayName
        toolTip = "点击后按下新的全局快捷键"
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var acceptsFirstResponder: Bool { true }

    @objc private func beginRecording() {
        guard !isRecording, isEnabled else { return }
        isRecording = true
        title = "请按新快捷键…（Esc 取消）"
        onRecordingChanged?(true)
        window?.makeFirstResponder(self)
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged]
        ) { [weak self] event in
            guard let self, self.isRecording else { return event }
            self.capture(event)
            return nil
        }
    }

    private func capture(_ event: NSEvent) {
        if event.keyCode == 53 {
            cancelRecording()
            return
        }

        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        var candidate = descriptor
        if event.type == .flagsChanged {
            guard event.keyCode == 54 || event.keyCode == 55 else {
                commandRecorderGesture.otherModifierChanged()
                title = "请继续按普通键组成快捷键…"
                return
            }
            guard let commandKeyCode = commandRecorderGesture.commandChanged(
                keyCode: event.keyCode
            ) else {
                let isDown = event.modifierFlags.contains(.command)
                title = isDown
                    ? "松开以使用\(event.keyCode == 55 ? "左⌘" : "右⌘")，或继续按组合键…"
                    : "请按新快捷键…（Esc 取消）"
                return
            }
            candidate.keyCode = commandKeyCode
            candidate.modifiers = UInt64(NSEvent.ModifierFlags.command.rawValue)
        } else {
            commandRecorderGesture.nonModifierKeyPressed()
            candidate.keyCode = event.keyCode
            candidate.modifiers = UInt64(flags.rawValue)
        }
        guard candidate.isValidGlobalShortcut else {
            NSSound.beep()
            title = "需含 ⌃/⌥/⌘，或单独按 Command"
            return
        }

        descriptor = candidate
        onRecorded?(candidate)
        finishRecording()
    }

    func cancelRecording() {
        guard isRecording else { return }
        finishRecording()
    }

    private func finishRecording() {
        isRecording = false
        commandRecorderGesture.reset()
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        title = descriptor.displayName
        onRecordingChanged?(false)
        if window?.firstResponder === self {
            window?.makeFirstResponder(nil)
        }
    }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }
}
