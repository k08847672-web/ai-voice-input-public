import Foundation
import VoiceInputCore

enum ASRWireProtocol: Equatable, Sendable {
    case voiceInputV1
    case voiceInkLegacy

    static func resolved(for url: URL) -> ASRWireProtocol {
        url.path == "/api/voice-input/stream" ? .voiceInkLegacy : .voiceInputV1
    }
}

struct ASRWireCodec: Sendable {
    let wireProtocol: ASRWireProtocol
    let sessionID: UUID

    init(url: URL, sessionID: UUID) {
        wireProtocol = .resolved(for: url)
        self.sessionID = sessionID
    }

    func startMessage(configuration: ASRStartConfiguration) throws -> String {
        let data: Data
        switch wireProtocol {
        case .voiceInputV1:
            data = try JSONEncoder().encode(
                ASRClientEnvelope.start(sessionID: sessionID, configuration: configuration)
            )
        case .voiceInkLegacy:
            data = try JSONEncoder().encode(
                LegacyStartEnvelope(
                    taskID: sessionID.uuidString.lowercased(),
                    language: Self.legacyLanguage(configuration.language)
                )
            )
        }
        return String(decoding: data, as: UTF8.self)
    }

    func stopMessage() throws -> String {
        let data: Data
        switch wireProtocol {
        case .voiceInputV1:
            data = try JSONEncoder().encode(ASRClientEnvelope.stop(sessionID: sessionID))
        case .voiceInkLegacy:
            data = try JSONEncoder().encode(LegacyStopEnvelope())
        }
        return String(decoding: data, as: UTF8.self)
    }

    func event(from data: Data) throws -> ASREvent {
        switch wireProtocol {
        case .voiceInputV1:
            let envelope = try JSONDecoder().decode(ASRServerEnvelope.self, from: data)
            if let serverSessionID = envelope.sessionID, serverSessionID != sessionID {
                throw ASRProtocolError.sessionMismatch
            }
            return try ASREvent(envelope: envelope)
        case .voiceInkLegacy:
            return try legacyEvent(from: data)
        }
    }

    private func legacyEvent(from data: Data) throws -> ASREvent {
        let envelope = try JSONDecoder().decode(LegacyServerEnvelope.self, from: data)
        if let taskID = envelope.taskID,
           UUID(uuidString: taskID) != sessionID
        {
            throw ASRProtocolError.sessionMismatch
        }
        switch envelope.type {
        case "ready":
            return .ready
        case "partial":
            return .partial(try Self.validTranscript(envelope.transcript, type: "partial"))
        case "final":
            return .final(try Self.validTranscript(envelope.transcript, type: "final"))
        case "error":
            let message = envelope.message ?? envelope.error ?? "识别服务返回未知错误"
            guard !message.isEmpty, message.unicodeScalars.count <= 1_000 else {
                throw ASRProtocolError.invalidEvent("error 缺少 message")
            }
            return .error(code: "legacy_server_error", message: message)
        default:
            let safeType = envelope.type.unicodeScalars.count <= 64 ? envelope.type : "unknown"
            throw ASRProtocolError.unknownEvent(safeType)
        }
    }

    private static func validTranscript(_ text: String?, type: String) throws -> String {
        guard let text else { throw ASRProtocolError.invalidEvent("\(type) 缺少 text") }
        guard text.unicodeScalars.count <= 100_000 else {
            throw ASRProtocolError.invalidEvent("\(type) text 过长")
        }
        return text
    }

    private static func legacyLanguage(_ language: String) -> String {
        guard language != "auto" else { return language }
        return language.split(separator: "-").first.map(String.init)?.lowercased() ?? "zh"
    }
}

private struct LegacyStartEnvelope: Encodable {
    let type = "start"
    let taskID: String
    let sampleRate = 16_000
    let channels = 1
    let format = "pcm_s16le"
    let language: String
    let partialSeconds = 0.8

    private enum CodingKeys: String, CodingKey {
        case type
        case taskID = "task_id"
        case sampleRate = "sample_rate"
        case channels
        case format
        case language
        case partialSeconds = "partial_seconds"
    }
}

private struct LegacyStopEnvelope: Encodable {
    let type = "end"
}

private struct LegacyTextContainer: Decodable {
    let text: String?
}

private struct LegacyServerEnvelope: Decodable {
    let type: String
    let taskID: String?
    let text: String?
    let result: LegacyTextContainer?
    let data: LegacyTextContainer?
    let message: String?
    let error: String?

    var transcript: String? {
        text ?? result?.text ?? data?.text
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case taskID = "task_id"
        case text
        case result
        case data
        case message
        case error
    }
}
