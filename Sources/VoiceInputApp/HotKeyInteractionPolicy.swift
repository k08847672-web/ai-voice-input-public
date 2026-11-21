import VoiceInputCore

enum HotKeySignal {
    case pressed
    case released
}

enum HotKeySessionStatus {
    case ready
    case recording
    case finalizing
    case inserting
}

enum HotKeyAction: Equatable {
    case begin
    case end
    case cancel
    case none
}

enum HotKeyInteractionPolicy {
    static func action(
        activationMode: HotKeyActivationMode,
        signal: HotKeySignal,
        sessionStatus: HotKeySessionStatus
    ) -> HotKeyAction {
        switch (activationMode, signal, sessionStatus) {
        case (.pressAndHold, .pressed, .ready),
             (.toggle, .pressed, .ready):
            .begin
        case (.pressAndHold, .released, .recording),
             (.toggle, .pressed, .recording):
            .end
        case (_, .pressed, .finalizing):
            .cancel
        default:
            .none
        }
    }
}
