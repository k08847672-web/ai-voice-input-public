import VoiceInputCore

enum ModifierOnlyHotKeyAction: Equatable {
    case scheduleHoldActivation
    case cancelHoldActivation
    case pressed
    case released
    case tapped
    case cancelled
}

enum ModifierOnlyPhysicalKeyTransition: Equatable {
    case down
    case up
}

struct ModifierOnlyPhysicalKeyState {
    private(set) var isDown = false
    private var ignoreUntilRelease = false

    mutating func reset(currentlyDown: Bool = false) {
        isDown = currentlyDown
        ignoreUntilRelease = currentlyDown
    }

    mutating func matchingFlagsChanged() -> ModifierOnlyPhysicalKeyTransition? {
        if ignoreUntilRelease {
            isDown = false
            ignoreUntilRelease = false
            return nil
        }
        isDown.toggle()
        return isDown ? .down : .up
    }
}

struct ModifierOnlyHotKeyGesture {
    private enum Phase: Equatable {
        case idle
        case pending(HotKeyActivationMode)
        case active
        case disqualified
    }

    private var phase: Phase = .idle

    mutating func modifierDown(
        activationMode: HotKeyActivationMode
    ) -> [ModifierOnlyHotKeyAction] {
        guard phase == .idle else { return [] }
        phase = .pending(activationMode)
        return activationMode == .pressAndHold ? [.scheduleHoldActivation] : []
    }

    mutating func activationDelayElapsed() -> [ModifierOnlyHotKeyAction] {
        guard phase == .pending(.pressAndHold) else { return [] }
        phase = .active
        return [.pressed]
    }

    mutating func otherKeyPressed() -> [ModifierOnlyHotKeyAction] {
        switch phase {
        case .pending(.pressAndHold):
            phase = .disqualified
            return [.cancelHoldActivation]
        case .pending(.toggle):
            phase = .disqualified
            return []
        case .active:
            phase = .disqualified
            return [.cancelled]
        case .idle, .disqualified:
            return []
        }
    }

    mutating func modifierUp() -> [ModifierOnlyHotKeyAction] {
        let actions: [ModifierOnlyHotKeyAction] = switch phase {
        case .pending(.pressAndHold): [.cancelHoldActivation]
        case .pending(.toggle): [.tapped]
        case .active: [.released]
        case .idle, .disqualified: []
        }
        phase = .idle
        return actions
    }

    mutating func reset() {
        phase = .idle
    }
}

struct ModifierOnlyHotKeyRecorderGesture {
    private var pendingKeyCode: UInt16?
    private var wasCombined = false
    private var leftCommandIsDown = false
    private var rightCommandIsDown = false

    mutating func commandChanged(keyCode: UInt16) -> UInt16? {
        guard keyCode == 54 || keyCode == 55 else { return nil }
        let isDown: Bool
        if keyCode == 55 {
            leftCommandIsDown.toggle()
            isDown = leftCommandIsDown
        } else {
            rightCommandIsDown.toggle()
            isDown = rightCommandIsDown
        }
        if isDown {
            if let pendingKeyCode, pendingKeyCode != keyCode {
                wasCombined = true
            } else if pendingKeyCode == nil {
                pendingKeyCode = keyCode
                wasCombined = false
            }
            return nil
        }

        guard pendingKeyCode == keyCode else { return nil }
        let recordedKeyCode = wasCombined ? nil : keyCode
        reset()
        return recordedKeyCode
    }

    mutating func otherModifierChanged() {
        if pendingKeyCode != nil { wasCombined = true }
    }

    mutating func nonModifierKeyPressed() {
        reset()
    }

    mutating func reset() {
        pendingKeyCode = nil
        wasCombined = false
        leftCommandIsDown = false
        rightCommandIsDown = false
    }
}
