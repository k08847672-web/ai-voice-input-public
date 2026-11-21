import XCTest
@testable import VoiceInputCore

final class DictionarySyncTests: XCTestCase {
    func testDerivesOnlyTheValidatedStandardServiceURL() throws {
        let url = try DictionarySyncURL.fromASR(
            "ws://100.91.11.111:19001/v1/asr/stream",
            allowInsecurePrivateNetwork: true
        )
        XCTAssertEqual(url.absoluteString, "http://100.91.11.111:19001/v1/dictionary")
        XCTAssertThrowsError(try DictionarySyncURL.fromASR(
            "ws://100.91.11.111:19000/api/voice-input/stream",
            allowInsecurePrivateNetwork: true
        ))
    }

    func testMergesIndependentEditsWithoutReplacingTheWholeTable() {
        let result = DictionarySyncMerge.merge(
            baseline: ["旧词": "Old"],
            local: ["旧词": "Old", "本机词": "Mac"],
            remote: ["旧词": "Old", "手机词": "Android"]
        )
        XCTAssertEqual(result.entries, ["旧词": "Old", "本机词": "Mac", "手机词": "Android"])
        XCTAssertTrue(result.conflicts.isEmpty)
    }

    func testOfflineDeleteSurvivesRemoteAddition() {
        let result = DictionarySyncMerge.merge(
            baseline: ["要删": "Removed"],
            local: [:],
            remote: ["要删": "Removed", "新词": "New"]
        )
        XCTAssertEqual(result.entries, ["新词": "New"])
    }

    func testSameSpokenConflictKeepsLocalAndReportsIt() {
        let result = DictionarySyncMerge.merge(
            baseline: ["词": "Old"],
            local: ["词": "Here"],
            remote: ["词": "There"]
        )
        XCTAssertEqual(result.entries, ["词": "Here"])
        XCTAssertEqual(result.conflicts, ["词"])
    }
}
