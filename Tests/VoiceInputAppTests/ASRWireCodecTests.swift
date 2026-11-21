import XCTest
@testable import VoiceInput
import VoiceInputCore

final class ASRWireCodecTests: XCTestCase {
    private let sessionID = UUID(uuidString: "C56A4180-65AA-42EC-A945-5FD21DEC0538")!

    func testLegacyProtocolIsSelectedOnlyForCurrentVoiceInkPath() throws {
        XCTAssertEqual(
            ASRWireProtocol.resolved(for: try XCTUnwrap(URL(string: "ws://100.86.28.63:19000/api/voice-input/stream"))),
            .voiceInkLegacy
        )
        XCTAssertEqual(
            ASRWireProtocol.resolved(for: try XCTUnwrap(URL(string: "wss://asr.example.com/v1/asr/stream"))),
            .voiceInputV1
        )
    }

    func testLegacyStartAndStopMessagesMatchCurrentServerContract() throws {
        let codec = try legacyCodec()
        let configuration = ASRStartConfiguration(
            language: "zh-CN",
            mode: .faithful,
            hotwords: [],
            dictionary: [:],
            style: "",
            sourceApplication: nil
        )
        let startData = try XCTUnwrap(codec.startMessage(configuration: configuration).data(using: .utf8))
        let start = try XCTUnwrap(JSONSerialization.jsonObject(with: startData) as? [String: Any])
        XCTAssertEqual(start["type"] as? String, "start")
        XCTAssertEqual(start["task_id"] as? String, sessionID.uuidString.lowercased())
        XCTAssertEqual(start["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(start["format"] as? String, "pcm_s16le")
        XCTAssertEqual(start["language"] as? String, "zh")

        let stopData = try XCTUnwrap(codec.stopMessage().data(using: .utf8))
        let stop = try XCTUnwrap(JSONSerialization.jsonObject(with: stopData) as? [String: Any])
        XCTAssertEqual(stop["type"] as? String, "end")
    }

    func testV1CodecPreservesStandardProtocolEnvelope() throws {
        let codec = ASRWireCodec(
            url: try XCTUnwrap(URL(string: "wss://asr.example.com/v1/asr/stream")),
            sessionID: sessionID
        )
        let configuration = ASRStartConfiguration(
            language: "zh-CN",
            mode: .faithful,
            hotwords: [],
            dictionary: [:],
            style: "",
            sourceApplication: nil
        )
        let startData = try XCTUnwrap(codec.startMessage(configuration: configuration).data(using: .utf8))
        let start = try JSONDecoder().decode(ASRClientEnvelope.self, from: startData)
        XCTAssertEqual(start.type, "start")
        XCTAssertEqual(start.sessionID, sessionID)

        let readyData = Data(
            #"{"type":"ready","session_id":"c56a4180-65aa-42ec-a945-5fd21dec0538"}"#.utf8
        )
        XCTAssertEqual(try codec.event(from: readyData), .ready)
    }

    func testLegacyEventsSupportAllObservedTranscriptShapes() throws {
        let codec = try legacyCodec()
        XCTAssertEqual(try codec.event(from: Data(#"{"type":"ready"}"#.utf8)), .ready)
        XCTAssertEqual(
            try codec.event(from: Data(#"{"type":"partial","result":{"text":"你好"}}"#.utf8)),
            .partial("你好")
        )
        XCTAssertEqual(
            try codec.event(from: Data(#"{"type":"final","data":{"text":"完成"}}"#.utf8)),
            .final("完成")
        )
    }

    func testLegacySessionMismatchIsRejected() throws {
        let codec = try legacyCodec()
        let data = Data(#"{"type":"ready","task_id":"00000000-0000-0000-0000-000000000000"}"#.utf8)
        XCTAssertThrowsError(try codec.event(from: data)) { error in
            XCTAssertEqual(error as? ASRProtocolError, .sessionMismatch)
        }
    }

    private func legacyCodec() throws -> ASRWireCodec {
        ASRWireCodec(
            url: try XCTUnwrap(URL(string: "ws://100.86.28.63:19000/api/voice-input/stream")),
            sessionID: sessionID
        )
    }
}
