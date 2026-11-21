import XCTest
@testable import VoiceInputCore

final class ASRProtocolTests: XCTestCase {
    func testStartEnvelopeUsesStableWireKeys() throws {
        let sessionID = UUID(uuidString: "C56A4180-65AA-42EC-A945-5FD21DEC0538")!
        let config = ASRStartConfiguration(
            language: "zh-CN",
            mode: .smart,
            hotwords: ["Codex"],
            dictionary: ["扣得克斯": "Codex"],
            style: "简洁",
            sourceApplication: "com.apple.TextEdit"
        )
        let data = try JSONEncoder().encode(ASRClientEnvelope.start(sessionID: sessionID, configuration: config))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "start")
        XCTAssertEqual(object["protocol_version"] as? Int, 1)
        let wireConfig = try XCTUnwrap(object["config"] as? [String: Any])
        XCTAssertEqual(wireConfig["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(wireConfig["source_application"] as? String, "com.apple.TextEdit")
    }

    func testServerEventsDecode() throws {
        let data = #"{"type":"partial","session_id":"c56a4180-65aa-42ec-a945-5fd21dec0538","text":"你好"}"#.data(using: .utf8)!
        let envelope = try JSONDecoder().decode(ASRServerEnvelope.self, from: data)
        XCTAssertEqual(try ASREvent(envelope: envelope), .partial("你好"))
    }

    func testURLValidationRejectsPlaintextRemoteHost() {
        XCTAssertThrowsError(try ASRURLValidator.validate("ws://asr.example.com/stream", allowInsecurePrivateNetwork: true))
        XCTAssertThrowsError(try ASRURLValidator.validate("wss://token@asr.example.com/stream", allowInsecurePrivateNetwork: false))
        XCTAssertThrowsError(try ASRURLValidator.validate("wss://asr.example.com/stream?token=secret", allowInsecurePrivateNetwork: false))
        XCTAssertNoThrow(try ASRURLValidator.validate("ws://127.0.0.1:8765/stream", allowInsecurePrivateNetwork: true))
        XCTAssertNoThrow(try ASRURLValidator.validate("ws://100.86.28.63:19000/stream", allowInsecurePrivateNetwork: true))
        XCTAssertThrowsError(try ASRURLValidator.validate("ws://100.86.28.63:19000/stream", allowInsecurePrivateNetwork: false))
        XCTAssertThrowsError(try ASRURLValidator.validate("ws://100.128.0.1:19000/stream", allowInsecurePrivateNetwork: true))
        XCTAssertThrowsError(try ASRURLValidator.validate("ws://100.invalid.86.28.63:19000/stream", allowInsecurePrivateNetwork: true))
        XCTAssertNoThrow(try ASRURLValidator.validate("wss://asr.example.com/stream", allowInsecurePrivateNetwork: false))
        XCTAssertThrowsError(
            try ASRURLValidator.validate(
                "wss://asr.example.invalid/v1/asr/stream",
                allowInsecurePrivateNetwork: false
            )
        ) { error in
            XCTAssertEqual(error as? ASRProtocolError, .placeholderServerURL)
        }
    }

    func testUntrustedErrorCodeIsNotPropagatedToDiagnostics() throws {
        let envelope = ASRServerEnvelope(
            type: "error",
            sessionID: nil,
            text: nil,
            code: "token=secret transcript=private",
            message: "可向用户显示，但不能进入诊断字段"
        )
        XCTAssertEqual(
            try ASREvent(envelope: envelope),
            .error(code: "server_error", message: "可向用户显示，但不能进入诊断字段")
        )
    }

    func testSharedProtocolFixtureMatchesClientEncodingAndServerDecoding() throws {
        let fixture = try Self.loadSharedFixture()
        let sessionID = try XCTUnwrap(UUID(uuidString: fixture.sessionID))
        let config = ASRStartConfiguration(
            language: "zh-CN",
            mode: .smart,
            hotwords: ["Codex"],
            dictionary: ["扣得克斯": "Codex"],
            style: "简洁",
            sourceApplication: "com.apple.TextEdit"
        )

        try Self.assertJSONEqual(
            JSONEncoder().encode(ASRClientEnvelope.start(sessionID: sessionID, configuration: config)),
            fixture.client.start
        )
        try Self.assertJSONEqual(
            JSONEncoder().encode(ASRClientEnvelope.stop(sessionID: sessionID)),
            fixture.client.stop
        )

        let events = try fixture.server.map {
            try ASREvent(envelope: JSONDecoder().decode(ASRServerEnvelope.self, from: $0))
        }
        XCTAssertEqual(events, [
            .ready,
            .partial("今天下午"),
            .final("今天下午三点开会。"),
            .error(code: "overloaded", message: "服务繁忙")
        ])
    }

    func testContentEventsRequireSessionAndText() {
        let missingSession = #"{"type":"ready"}"#.data(using: .utf8)!
        let missingText = #"{"type":"final","session_id":"c56a4180-65aa-42ec-a945-5fd21dec0538"}"#
            .data(using: .utf8)!

        XCTAssertThrowsError(try ASREvent(envelope: JSONDecoder().decode(ASRServerEnvelope.self, from: missingSession)))
        XCTAssertThrowsError(try ASREvent(envelope: JSONDecoder().decode(ASRServerEnvelope.self, from: missingText)))
    }

    func testServerEventContentLimitsPreventUnboundedUIData() {
        let oversizedError = ASRServerEnvelope(
            type: "error",
            sessionID: nil,
            text: nil,
            code: "backend_error",
            message: String(repeating: "x", count: 1_001)
        )
        let oversizedFinal = ASRServerEnvelope(
            type: "final",
            sessionID: UUID(),
            text: String(repeating: "字", count: 100_001),
            code: nil,
            message: nil
        )
        XCTAssertThrowsError(try ASREvent(envelope: oversizedError))
        XCTAssertThrowsError(try ASREvent(envelope: oversizedFinal))
    }

    func testClientConfigurationEnforcesServerLimitsBeforeConnecting() throws {
        let valid = ASRStartConfiguration(
            language: "zh-CN",
            mode: .smart,
            hotwords: ["Codex"],
            dictionary: ["扣得克斯": "Codex"],
            style: "简洁",
            sourceApplication: "com.apple.TextEdit"
        )
        XCTAssertNoThrow(try valid.validate())

        let tooManyHotwords = ASRStartConfiguration(
            language: "zh-CN",
            mode: .smart,
            hotwords: Array(repeating: "词", count: 501),
            dictionary: [:],
            style: "",
            sourceApplication: nil
        )
        XCTAssertThrowsError(try tooManyHotwords.validate()) { error in
            XCTAssertEqual(error as? ASRConfigurationError, .invalidHotwords)
        }

        let oversizedStyle = ASRStartConfiguration(
            language: "zh-CN",
            mode: .smart,
            hotwords: [],
            dictionary: [:],
            style: String(repeating: "字", count: 2_001),
            sourceApplication: nil
        )
        XCTAssertThrowsError(try oversizedStyle.validate()) { error in
            XCTAssertEqual(error as? ASRConfigurationError, .invalidStyle)
        }
    }

    private struct SharedFixture: Decodable {
        struct ClientMessages: Decodable {
            let start: Data
            let stop: Data

            enum CodingKeys: String, CodingKey {
                case start
                case stop
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                start = try Self.jsonData(container.decode(JSONValue.self, forKey: .start))
                stop = try Self.jsonData(container.decode(JSONValue.self, forKey: .stop))
            }

            private static func jsonData(_ value: JSONValue) throws -> Data {
                try JSONEncoder().encode(value)
            }
        }

        let sessionID: String
        let client: ClientMessages
        let server: [Data]

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case client
            case server
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sessionID = try container.decode(String.self, forKey: .sessionID)
            client = try container.decode(ClientMessages.self, forKey: .client)
            server = try container.decode([JSONValue].self, forKey: .server).map {
                try JSONEncoder().encode($0)
            }
        }
    }

    private enum JSONValue: Codable, Equatable {
        case object([String: JSONValue])
        case array([JSONValue])
        case string(String)
        case number(Int)
        case bool(Bool)
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
            else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
            else if let value = try? container.decode(String.self) { self = .string(value) }
            else if let value = try? container.decode(Bool.self) { self = .bool(value) }
            else { self = .number(try container.decode(Int.self)) }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case let .object(value): try container.encode(value)
            case let .array(value): try container.encode(value)
            case let .string(value): try container.encode(value)
            case let .number(value): try container.encode(value)
            case let .bool(value): try container.encode(value)
            case .null: try container.encodeNil()
            }
        }
    }

    private static func loadSharedFixture() throws -> SharedFixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/asr_v1.json")
        return try JSONDecoder().decode(SharedFixture.self, from: Data(contentsOf: url))
    }

    private static func assertJSONEqual(
        _ actual: Data,
        _ expected: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: actual) as? NSDictionary,
            try JSONSerialization.jsonObject(with: expected) as? NSDictionary,
            file: file,
            line: line
        )
    }
}
