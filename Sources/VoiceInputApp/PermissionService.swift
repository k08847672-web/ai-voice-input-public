import ApplicationServices
import AppKit
import AVFoundation
import CoreGraphics
import Foundation

struct PermissionSnapshot {
    let microphone: Bool
    let accessibility: Bool
    let inputMonitoring: Bool

    var allGranted: Bool { microphone && accessibility && inputMonitoring }
}

enum PermissionService {
    enum PrivacyPane: String {
        case microphone = "Privacy_Microphone"
        case accessibility = "Privacy_Accessibility"
        case inputMonitoring = "Privacy_ListenEvent"
    }

    static func snapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            accessibility: AXIsProcessTrusted(),
            inputMonitoring: CGPreflightListenEventAccess()
        )
    }

    static func requestMicrophone() async -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { return true }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func requestInputMonitoring() -> Bool {
        CGRequestListenEventAccess()
    }

    @MainActor
    static func openSystemSettings(_ pane: PrivacyPane) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
