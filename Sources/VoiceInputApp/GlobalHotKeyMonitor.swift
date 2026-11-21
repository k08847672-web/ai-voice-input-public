import CoreGraphics
import Foundation
import VoiceInputCore

final class GlobalHotKeyMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var descriptor: HotKeyDescriptor = .default
    private var pressed = false
    private var modifierGesture = ModifierOnlyHotKeyGesture()
    private var modifierPhysicalKey = ModifierOnlyPhysicalKeyState()
    private var modifierActivationWorkItem: DispatchWorkItem?
    var onPressed: (() -> Void)?
    var onReleased: (() -> Void)?
    var onCancelled: (() -> Void)?
    var onEscape: (() -> Void)?

    init(descriptor: HotKeyDescriptor = .default) {
        self.descriptor = descriptor
    }

    func start(descriptor: HotKeyDescriptor) throws {
        stop()
        guard descriptor.isValidGlobalShortcut else {
            throw HotKeyError.invalidShortcut
        }
        self.descriptor = descriptor
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.rightMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.otherMouseDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<GlobalHotKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                monitor.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw HotKeyError.cannotCreateEventTap
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            throw HotKeyError.cannotCreateEventTap
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        if descriptor.isCommandModifierOnly {
            modifierPhysicalKey.reset(currentlyDown: Self.isKeyDown(descriptor.keyCode))
        }
    }

    func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        pressed = false
        modifierActivationWorkItem?.cancel()
        modifierActivationWorkItem = nil
        modifierGesture.reset()
        modifierPhysicalKey.reset()
    }

    func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            modifierActivationWorkItem?.cancel()
            modifierActivationWorkItem = nil
            modifierGesture.reset()
            modifierPhysicalKey.reset(
                currentlyDown: descriptor.isCommandModifierOnly && Self.isKeyDown(descriptor.keyCode)
            )
            pressed = false
            return
        }
        guard !PasteKeystroke.isOwnEvent(event) else { return }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyDown, keyCode == 53 {
            DispatchQueue.main.async { [weak self] in self?.onEscape?() }
        }
        if descriptor.isCommandModifierOnly {
            handleModifierOnly(type: type, keyCode: keyCode)
            return
        }
        guard keyCode == descriptor.keyCode else { return }

        if type == .keyDown {
            let relevantFlags = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
            guard relevantFlags.rawValue == descriptor.modifiers, !pressed else { return }
            pressed = true
            DispatchQueue.main.async { [weak self] in self?.onPressed?() }
        } else if type == .keyUp, pressed {
            pressed = false
            DispatchQueue.main.async { [weak self] in self?.onReleased?() }
        }
    }

    private func handleModifierOnly(type: CGEventType, keyCode: UInt16) {
        if type == .flagsChanged, keyCode == descriptor.keyCode {
            switch modifierPhysicalKey.matchingFlagsChanged() {
            case .down:
                perform(modifierGesture.modifierDown(activationMode: descriptor.activationMode))
            case .up:
                perform(modifierGesture.modifierUp())
            case nil:
                modifierGesture.reset()
            }
        } else if modifierPhysicalKey.isDown,
                  type == .keyDown || type == .flagsChanged
                    || type == .leftMouseDown || type == .rightMouseDown
                    || type == .otherMouseDown
        {
            perform(modifierGesture.otherKeyPressed())
        }
    }

    private static func isKeyDown(_ keyCode: UInt16) -> Bool {
        CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
    }

    private func perform(_ actions: [ModifierOnlyHotKeyAction]) {
        for action in actions {
            switch action {
            case .scheduleHoldActivation:
                modifierActivationWorkItem?.cancel()
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.perform(self.modifierGesture.activationDelayElapsed())
                }
                modifierActivationWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(180), execute: workItem)
            case .cancelHoldActivation:
                modifierActivationWorkItem?.cancel()
                modifierActivationWorkItem = nil
            case .pressed:
                modifierActivationWorkItem = nil
                DispatchQueue.main.async { [weak self] in self?.onPressed?() }
            case .released:
                DispatchQueue.main.async { [weak self] in self?.onReleased?() }
            case .tapped:
                DispatchQueue.main.async { [weak self] in
                    self?.onPressed?()
                    self?.onReleased?()
                }
            case .cancelled:
                DispatchQueue.main.async { [weak self] in self?.onCancelled?() }
            }
        }
    }
}

enum HotKeyError: LocalizedError {
    case cannotCreateEventTap
    case invalidShortcut

    var errorDescription: String? {
        switch self {
        case .cannotCreateEventTap:
            "无法监听全局快捷键，请授予辅助功能和输入监控权限"
        case .invalidShortcut:
            "快捷键需包含 Control、Option 或 Command；左右 Command 与 F1–F20 可单独使用"
        }
    }
}
