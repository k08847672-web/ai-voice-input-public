import AppKit
import XCTest
@testable import VoiceInput

@MainActor
final class TextInsertionServiceTests: XCTestCase {
    func testRemotePreparationSeesFinalTextBeforeRelayAndPaste() async throws {
        for bundle in ["com.apple.ScreenSharing", "com.netease.uuremote"] {
            let pasteboard = makePasteboard()
            defer { pasteboard.releaseGlobally() }
            pasteboard.setString("previous clipboard", forType: .string)
            let clock = ContinuousClock()
            var preparedAt: ContinuousClock.Instant?
            var phases: [String] = []
            try await TextInsertionService().paste(
                "voice input test", using: pasteboard, for: bundle,
                preparePaste: {
                    XCTAssertEqual(pasteboard.string(forType: .string), "voice input test")
                    phases.append("prepared")
                    preparedAt = clock.now
                }
            ) {
                XCTAssertEqual(phases, ["prepared"])
                XCTAssertEqual(pasteboard.string(forType: .string), "voice input test")
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(preparedAt).duration(to: clock.now), .milliseconds(250))
                phases.append("paste")
            }
            XCTAssertEqual(phases, ["prepared", "paste"])
            XCTAssertEqual(pasteboard.string(forType: .string), "voice input test")
        }
    }

    func testRemoteClientsKeepFinalTextAvailableAfterPaste() async throws {
        for bundleIdentifier in ["com.apple.ScreenSharing", "com.netease.uuremote"] {
            let pasteboard = makePasteboard()
            defer { pasteboard.releaseGlobally() }
            pasteboard.setString("previous clipboard", forType: .string)
            let clock = ContinuousClock()
            let started = clock.now
            var pasteCount = 0

            try await TextInsertionService().paste(
                "voice input test", using: pasteboard, for: bundleIdentifier
            ) {
                pasteCount += 1
                XCTAssertEqual(pasteboard.string(forType: .string), "voice input test")
                XCTAssertGreaterThanOrEqual(started.duration(to: clock.now), .milliseconds(250))
            }

            try await Task.sleep(for: .milliseconds(400))
            XCTAssertEqual(pasteCount, 1)
            XCTAssertEqual(pasteboard.string(forType: .string), "voice input test")
        }
    }

    func testLocalApplicationsRestoreEveryOriginalClipboardType() async throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let customType = NSPasteboard.PasteboardType("com.aivoiceinput.test-data")
        let item = NSPasteboardItem()
        item.setString("previous clipboard", forType: .string)
        item.setData(Data([1, 2, 3]), forType: customType)
        pasteboard.writeObjects([item])

        try await TextInsertionService().paste(
            "voice input test", using: pasteboard, for: "com.apple.TextEdit"
        ) {
            XCTAssertEqual(pasteboard.string(forType: .string), "voice input test")
        }

        XCTAssertEqual(pasteboard.string(forType: .string), "previous clipboard")
        XCTAssertEqual(pasteboard.data(forType: customType), Data([1, 2, 3]))
    }

    func testNewUserCopyIsNeverReplacedAfterPaste() async throws {
        for bundleIdentifier in ["com.apple.ScreenSharing", "com.netease.uuremote", "com.apple.TextEdit"] {
            let pasteboard = makePasteboard()
            defer { pasteboard.releaseGlobally() }
            pasteboard.setString("previous clipboard", forType: .string)

            try await TextInsertionService().paste(
                "voice input test", using: pasteboard, for: bundleIdentifier
            ) {
                pasteboard.clearContents()
                pasteboard.setString("new user copy", forType: .string)
            }

            XCTAssertEqual(pasteboard.string(forType: .string), "new user copy")
        }
    }

    func testPasteFailureRestoresOnlyLocalClipboard() async {
        for bundleIdentifier in ["com.apple.ScreenSharing", "com.netease.uuremote", "com.apple.TextEdit"] {
            let pasteboard = makePasteboard()
            defer { pasteboard.releaseGlobally() }
            pasteboard.setString("previous clipboard", forType: .string)

            do {
                try await TextInsertionService().paste(
                    "voice input test", using: pasteboard, for: bundleIdentifier
                ) {
                    throw TextInsertionError.insertionFailed
                }
                XCTFail("Expected paste failure")
            } catch {}

            XCTAssertEqual(
                pasteboard.string(forType: .string),
                bundleIdentifier == "com.apple.TextEdit" ? "previous clipboard" : "voice input test"
            )
        }
    }

    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: .init("com.aivoiceinput.tests.\(UUID().uuidString)"))
    }
}
