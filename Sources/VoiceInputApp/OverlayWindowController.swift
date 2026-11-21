import AppKit
import SwiftUI

@MainActor
final class OverlayState: ObservableObject {
    @Published var title = ""
    @Published var transcript = ""
    @Published var level: Float = 0
    @Published var isRecording = false
}

@MainActor
final class OverlayWindowController {
    private let state: OverlayState
    private var panel: NSPanel?

    init(state: OverlayState) {
        self.state = state
    }

    func show() {
        let panel = panel ?? makePanel()
        position(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 104),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: OverlayContent(state: state))
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: visible.midX - panel.frame.width / 2,
            y: visible.minY + 72
        )
        panel.setFrameOrigin(origin)
    }
}

private struct OverlayContent: View {
    @ObservedObject var state: OverlayState

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(state.isRecording ? Color.red.opacity(0.18) : Color.accentColor.opacity(0.18))
                    .frame(width: 42, height: 42)
                Image(systemName: state.isRecording ? "waveform" : "ellipsis")
                    .foregroundStyle(state.isRecording ? .red : .primary)
                    .symbolEffect(.variableColor.iterative, isActive: state.isRecording)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(state.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(
                    state.transcript.isEmpty
                        ? (state.isRecording ? "请讲话…" : "等待识别结果…")
                        : state.transcript
                )
                    .font(.body)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            LevelMeter(level: state.level)
                .frame(width: 56, height: 30)
        }
        .padding(.horizontal, 18)
        .frame(width: 520, height: 104)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12))
        }
    }
}

private struct LevelMeter: View {
    let level: Float

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0 ..< 5, id: \.self) { index in
                Capsule()
                    .fill(Double(level) * 5 > Double(index) ? Color.red : Color.secondary.opacity(0.25))
                    .frame(width: 6, height: CGFloat(8 + index * 4))
            }
        }
    }
}
