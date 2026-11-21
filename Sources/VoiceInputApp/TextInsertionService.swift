import ApplicationServices
import AppKit
import Carbon
import CoreGraphics
import Foundation

enum TextInsertionError: LocalizedError {
    case accessibilityDenied
    case noFocusedElement
    case secureField
    case insertionFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityDenied: "没有辅助功能权限，无法插入文字"
        case .noFocusedElement: "没有找到当前输入光标"
        case .secureField: "为保护敏感信息，安全输入框中已停用语音输入"
        case .insertionFailed: "无法向当前应用插入文字"
        }
    }
}

struct TextInsertionTarget {
    let application: NSRunningApplication
    let element: AXUIElement?
    var processIdentifier: pid_t { application.processIdentifier }
}

@MainActor
final class TextInsertionService {
    func captureTarget() throws -> TextInsertionTarget {
        try validateInputAccess()
        guard let application = NSWorkspace.shared.frontmostApplication else {
            throw TextInsertionError.noFocusedElement
        }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        return try captureTarget(
            in: application,
            applicationFocusedElement: { self.focusedElement(of: appElement) },
            systemFocusedElement: { self.focusedElement(of: AXUIElementCreateSystemWide()) }
        )
    }

    // Some custom editors do not expose an AX caret. Keep the application the
    // user focused at the start so its native paste path remains available.
    func captureTarget(
        in application: NSRunningApplication,
        applicationFocusedElement: () -> AXUIElement?,
        systemFocusedElement: () -> AXUIElement?
    ) throws -> TextInsertionTarget {
        guard !application.isTerminated else { throw TextInsertionError.noFocusedElement }
        let element = matchingElement(applicationFocusedElement(), processIdentifier: application.processIdentifier)
            ?? matchingElement(systemFocusedElement(), processIdentifier: application.processIdentifier)
        if let element, isSecure(element) { throw TextInsertionError.secureField }
        return TextInsertionTarget(application: application, element: element)
    }

    func insert(_ text: String, into target: TextInsertionTarget) async throws {
        _ = try validatedElement(for: target)

        // Pasting is more reliable than AXSelectedText for Electron/contenteditable
        // controls, some of which report AX success without updating their model.
        do {
            try await paste(text, into: target)
            return
        } catch {
            guard let element = try validatedElement(for: target) else { throw error }
            guard AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                text as CFTypeRef
            ) == .success else {
                throw TextInsertionError.insertionFailed
            }
        }
    }

    private func validateInputAccess() throws {
        guard AXIsProcessTrusted() else { throw TextInsertionError.accessibilityDenied }
        guard !IsSecureEventInputEnabled() else { throw TextInsertionError.secureField }
    }

    private func validatedElement(for target: TextInsertionTarget) throws -> AXUIElement? {
        try validateInputAccess()
        guard !target.application.isTerminated else { throw TextInsertionError.noFocusedElement }
        guard let element = target.element else { return nil }
        guard matchingElement(element, processIdentifier: target.processIdentifier) != nil else {
            throw TextInsertionError.noFocusedElement
        }
        if isSecure(element) { throw TextInsertionError.secureField }
        return element
    }

    private func matchingElement(_ element: AXUIElement?, processIdentifier expected: pid_t) -> AXUIElement? {
        guard let element else { return nil }
        var processIdentifier = pid_t()
        guard AXUIElementGetPid(element, &processIdentifier) == .success,
              processIdentifier == expected
        else {
            return nil
        }
        return element
    }

    private func focusedElement(of owner: AXUIElement) -> AXUIElement? {
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            owner,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success, let focusedValue else {
            return nil
        }
        guard CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return nil
        }
        // Core Foundation does not offer a conditional Swift cast for AXUIElement.
        // The runtime type-ID check above makes this bridge safe.
        return unsafeBitCast(focusedValue, to: AXUIElement.self)
    }

    private func isSecure(_ element: AXUIElement) -> Bool {
        stringAttribute(kAXSubroleAttribute, of: element) == kAXSecureTextFieldSubrole as String
    }

    private func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func paste(_ text: String, into target: TextInsertionTarget) async throws {
        let application = target.application
        let isRemote = PasteKeystroke.isRemoteClient(application.bundleIdentifier)
        if !isRemote { try await activateOriginalTarget(target) }

        try await paste(text, using: .general, for: application.bundleIdentifier, preparePaste: {
            guard isRemote else { return }
            // Only remote clients require a real application-focus edge after
            // final text is on the clipboard. Do not create or open a window.
            NSApplication.shared.activate(ignoringOtherApps: true)
            try? await Task.sleep(for: .milliseconds(120))
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else {
                throw TextInsertionError.insertionFailed
            }
            try await self.activateOriginalTarget(target)
        }) {
            _ = try self.validatedElement(for: target)
            guard Self.matchesOriginalApplication(
                target, frontmostProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier
            ) else {
                throw TextInsertionError.insertionFailed
            }
            try await PasteKeystroke.post(for: application.bundleIdentifier)
        }
    }

    private func activateOriginalTarget(_ target: TextInsertionTarget) async throws {
        let application = target.application
        guard !application.isTerminated, application.activate(options: [])
        else {
            throw TextInsertionError.insertionFailed
        }
        let appElement = AXUIElementCreateApplication(target.processIdentifier)
        _ = AXUIElementSetAttributeValue(
            appElement,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
        if let element = target.element {
            _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        try? await Task.sleep(for: .milliseconds(120))
    }

    static func matchesOriginalApplication(_ target: TextInsertionTarget, frontmostProcessIdentifier: pid_t?) -> Bool {
        !target.application.isTerminated && frontmostProcessIdentifier == target.processIdentifier
    }

    func paste(
        _ text: String,
        using pasteboard: NSPasteboard,
        for bundleIdentifier: String?,
        preparePaste: () async throws -> Void = {},
        sendPaste: () async throws -> Void
    ) async throws {
        let isRemoteClient = bundleIdentifier == "com.apple.ScreenSharing"
            || bundleIdentifier == "com.netease.uuremote"
        let snapshot = isRemoteClient ? nil : PasteboardSnapshot.capture(pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw TextInsertionError.insertionFailed
        }
        let insertedChangeCount = pasteboard.changeCount
        do {
            try await preparePaste()
            if isRemoteClient {
                // The existing relay window follows restoration of the original
                // remote application; final text remains on the clipboard.
                try? await Task.sleep(for: .milliseconds(250))
            }
            try await sendPaste()
        } catch {
            snapshot?.restore(to: pasteboard)
            throw error
        }
        guard let snapshot else { return }
        try? await Task.sleep(for: .milliseconds(350))
        if pasteboard.changeCount == insertedChangeCount {
            snapshot.restore(to: pasteboard)
        }
    }
}

enum PasteKeystroke {
    static let eventTag: Int64 = 0x5649_5041_5354_45

    static func isOwnEvent(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == eventTag
    }

    static func isRemoteClient(_ bundleIdentifier: String?) -> Bool {
        bundleIdentifier == "com.apple.ScreenSharing" || bundleIdentifier == "com.netease.uuremote"
    }

    static func events(for bundleIdentifier: String?) throws -> [CGEvent] {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            throw TextInsertionError.insertionFailed
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        var events = [down, up]
        if isRemoteClient(bundleIdentifier) {
            // IOLLEvent.h: NX_DEVICELCMDKEYMASK. Remote clients distinguish
            // the physical left/right modifier from the generic Command bit.
            let leftCommandFlags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x00000008)
            guard let commandDown = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: true),
                  let commandUp = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: false) else {
                throw TextInsertionError.insertionFailed
            }
            commandDown.type = .flagsChanged
            commandDown.flags = leftCommandFlags
            down.flags = leftCommandFlags
            up.flags = leftCommandFlags
            commandUp.type = .flagsChanged
            commandUp.flags = []
            events = [commandDown, down, up, commandUp]
        }
        for event in events { event.setIntegerValueField(.eventSourceUserData, value: eventTag) }
        return events
    }

    static func post(for bundleIdentifier: String?) async throws {
        let events = try events(for: bundleIdentifier)
        for (index, event) in events.enumerated() {
            event.post(tap: .cghidEventTap)
            if isRemoteClient(bundleIdentifier), index < events.count - 1 {
                // Keep modifier transitions ordered for clients that track physical
                // key state. Always deliver the release, even if the task cancels.
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }
}

private struct PasteboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(_ pasteboard: NSPasteboard) -> Self {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
        return Self(items: items)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}
