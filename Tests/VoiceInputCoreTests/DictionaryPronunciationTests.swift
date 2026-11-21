import XCTest
@testable import VoiceInputCore

final class DictionaryPronunciationTests: XCTestCase {
    func testKeepsRawASRSpellingWithoutSentencePunctuation() {
        XCTAssertEqual(DictionaryPronunciation.spokenForm(from: "  hutellgall。  "), "hutellgall")
        XCTAssertEqual(DictionaryPronunciation.spokenForm(from: "C++"), "C++")
        XCTAssertEqual(DictionaryPronunciation.spokenForm(from: "Git Hub"), "Git Hub")
    }

    func testRejectsMissingOrOversizedPronunciation() {
        XCTAssertNil(DictionaryPronunciation.spokenForm(from: "！？"))
        XCTAssertNil(DictionaryPronunciation.spokenForm(from: String(repeating: "a", count: 101)))
    }
}
