import Foundation

public enum RecognitionPhase: String, Equatable, Sendable {
    case idle
    case connecting
    case listening
    case finalizingAwaitingReady = "finalizing_awaiting_ready"
    case finalizing
    case inserting
    case failed
}

public enum RecognitionSignal: String, Equatable, Sendable {
    case begin
    case ready
    case partial
    case stop
    case final
    case inserted
    case fail
    case cancel
}

public struct RecognitionSessionState: Equatable, Sendable {
    public private(set) var phase: RecognitionPhase

    public init(phase: RecognitionPhase = .idle) {
        self.phase = phase
    }

    @discardableResult
    public mutating func apply(_ signal: RecognitionSignal) throws -> RecognitionPhase {
        let next: RecognitionPhase
        switch (phase, signal) {
        case (.idle, .begin), (.failed, .begin):
            next = .connecting
        case (.connecting, .ready):
            next = .listening
        case (.listening, .partial):
            next = .listening
        case (.finalizing, .partial):
            next = .finalizing
        case (.connecting, .stop):
            next = .finalizingAwaitingReady
        case (.listening, .stop):
            next = .finalizing
        case (.finalizingAwaitingReady, .ready):
            next = .finalizing
        case (.finalizing, .final):
            next = .inserting
        case (.inserting, .inserted):
            next = .idle
        case (.idle, .cancel), (.connecting, .cancel), (.listening, .cancel),
             (.finalizingAwaitingReady, .cancel), (.finalizing, .cancel),
             (.inserting, .cancel), (.failed, .cancel):
            next = .idle
        case (_, .fail):
            next = .failed
        default:
            throw RecognitionTransitionError.invalidTransition(from: phase, signal: signal)
        }
        phase = next
        return next
    }
}

public enum RecognitionTransitionError: LocalizedError, Equatable, Sendable {
    case invalidTransition(from: RecognitionPhase, signal: RecognitionSignal)

    public var errorDescription: String? {
        switch self {
        case let .invalidTransition(phase, signal):
            "识别协议事件顺序无效：\(phase.rawValue) + \(signal.rawValue)"
        }
    }
}
