import Foundation
import XCTest
@testable import VoiceInputMobileShared

@MainActor
final class SharedTranscriptStoreTests: XCTestCase {
    func testPublishedTranscriptCanOnlyBeConsumedOnce() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(store.publishFinal("  测试文字  ", at: now))
        XCTAssertEqual(store.peek(at: now)?.text, "测试文字")
        XCTAssertEqual(store.consume(at: now), "测试文字")
        XCTAssertNil(store.consume(at: now))
    }

    func testExpiredTranscriptIsRemoved() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let createdAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(store.publishFinal("过期文字", at: createdAt))

        let expiredAt = createdAt.addingTimeInterval(
            VoiceInputMobileConfiguration.pendingTranscriptLifetime
        )
        XCTAssertNil(store.peek(at: expiredAt))
        XCTAssertNil(store.consume(at: expiredAt))
    }

    func testInvalidFinalClearsPreviousValue() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertTrue(store.publishFinal("旧文字"))
        XCTAssertFalse(store.publishFinal("   "))
        XCTAssertNil(store.peek())
    }

    private func makeStore() -> (SharedTranscriptStore, UserDefaults, String) {
        let suiteName = "SharedTranscriptStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (SharedTranscriptStore(defaults: defaults), defaults, suiteName)
    }
}
