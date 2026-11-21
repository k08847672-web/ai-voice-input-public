import Foundation

public enum VoiceInputMobileConfiguration {
    public static let appGroupIdentifier = "group.com.aivoiceinput.shared"
    public static let pendingTranscriptLifetime: TimeInterval = 10 * 60
}

public struct PendingTranscript: Codable, Equatable, Sendable {
    public let text: String
    public let createdAt: Date

    public init(text: String, createdAt: Date) {
        self.text = text
        self.createdAt = createdAt
    }

    public func isExpired(
        at date: Date,
        lifetime: TimeInterval = VoiceInputMobileConfiguration.pendingTranscriptLifetime
    ) -> Bool {
        date.timeIntervalSince(createdAt) >= lifetime
    }
}

@MainActor
public final class SharedTranscriptStore {
    private static let pendingTranscriptKey = "pending-transcript-v1"
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public convenience init?(
        suiteName: String = VoiceInputMobileConfiguration.appGroupIdentifier
    ) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
        self.init(defaults: defaults)
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    @discardableResult
    public func publishFinal(_ text: String, at date: Date = Date()) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.unicodeScalars.count <= 100_000 else {
            clear()
            return false
        }
        do {
            let data = try encoder.encode(PendingTranscript(text: normalized, createdAt: date))
            defaults.set(data, forKey: Self.pendingTranscriptKey)
            return true
        } catch {
            clear()
            return false
        }
    }

    public func peek(at date: Date = Date()) -> PendingTranscript? {
        guard let pending = decodedPendingTranscript() else {
            clear()
            return nil
        }
        guard !pending.isExpired(at: date) else {
            clear()
            return nil
        }
        return pending
    }

    public func consume(at date: Date = Date()) -> String? {
        let pending = decodedPendingTranscript()
        clear()
        guard let pending, !pending.isExpired(at: date) else { return nil }
        return pending.text
    }

    public func clear() {
        defaults.removeObject(forKey: Self.pendingTranscriptKey)
    }

    private func decodedPendingTranscript() -> PendingTranscript? {
        guard let data = defaults.data(forKey: Self.pendingTranscriptKey) else { return nil }
        return try? decoder.decode(PendingTranscript.self, from: data)
    }
}
