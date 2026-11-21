import XCTest
@testable import VoiceInputCore

final class TextPostProcessorTests: XCTestCase {
    func testLongestDictionaryEntryWinsFirst() {
        let entries = [
            DictionaryEntry(spoken: "小明", written: "Xiao Ming"),
            DictionaryEntry(spoken: "小明同学", written: "Ming")
        ]
        XCTAssertEqual(TextPostProcessor.applyDictionary(entries, to: "小明同学和小明"), "Ming和Xiao Ming")
    }

    func testNormalizationDoesNotChangeMeaning() {
        XCTAssertEqual(TextPostProcessor.normalized(" 你好  ，  世界。 "), "你好， 世界。")
    }

    func testDictionaryDoesNotReplaceInsideItsOwnOutput() {
        let entries = [
            DictionaryEntry(spoken: "甲", written: "乙"),
            DictionaryEntry(spoken: "乙", written: "丙")
        ]
        XCTAssertEqual(TextPostProcessor.applyDictionary(entries, to: "甲乙"), "乙丙")
    }
}
