import AppKit
import ApplicationServices
import CoreGraphics
import XCTest
import VoiceInputCore
@testable import VoiceInput

@MainActor
final class InsertionTargetAndKeystrokeTests: XCTestCase {
    private func runningApplication() throws -> NSRunningApplication {
        // An unbundled SwiftPM XCTest process is not an NSRunningApplication.
        // Only app metadata is needed; no contents or focus are changed.
        let application = try XCTUnwrap(NSWorkspace.shared.frontmostApplication)
        XCTAssertFalse(application.isTerminated)
        return application
    }

    func testApplicationFocusIsPreferredWithoutReadingSystemFocus() throws {
        let application = try runningApplication()
        let element = AXUIElementCreateApplication(application.processIdentifier)
        var queriedSystem = false
        let target = try TextInsertionService().captureTarget(
            in: application, applicationFocusedElement: { element }, systemFocusedElement: {
                queriedSystem = true
                return nil
            }
        )
        XCTAssertEqual(target.processIdentifier, application.processIdentifier)
        XCTAssertTrue(CFEqual(try XCTUnwrap(target.element), element))
        XCTAssertFalse(queriedSystem)
    }

    func testSystemFocusFallbackMustBelongToOriginalApplication() throws {
        let application = try runningApplication()
        let element = AXUIElementCreateApplication(application.processIdentifier)
        let other = AXUIElementCreateApplication(application.processIdentifier + 1)
        let service = TextInsertionService()
        let target = try service.captureTarget(
            in: application, applicationFocusedElement: { other }, systemFocusedElement: { element }
        )
        XCTAssertTrue(CFEqual(try XCTUnwrap(target.element), element))
        let mismatched = try service.captureTarget(
            in: application, applicationFocusedElement: { nil }, systemFocusedElement: { other }
        )
        XCTAssertNil(mismatched.element)
        XCTAssertEqual(mismatched.processIdentifier, application.processIdentifier)
    }

    func testMissingAXFocusKeepsOriginalApplicationForNativePaste() throws {
        let application = try runningApplication()
        let target = try TextInsertionService().captureTarget(
            in: application, applicationFocusedElement: { nil }, systemFocusedElement: { nil }
        )
        XCTAssertNil(target.element)
        XCTAssertEqual(target.processIdentifier, application.processIdentifier)
        XCTAssertTrue(TextInsertionService.matchesOriginalApplication(target, frontmostProcessIdentifier: application.processIdentifier))
        XCTAssertFalse(TextInsertionService.matchesOriginalApplication(target, frontmostProcessIdentifier: application.processIdentifier + 1))
        XCTAssertFalse(TextInsertionService.matchesOriginalApplication(target, frontmostProcessIdentifier: nil))
    }

    func testRemotePasteConstructsCompleteTaggedModifierSequence() throws {
        for bundle in ["com.apple.ScreenSharing", "com.netease.uuremote"] {
            let events = try PasteKeystroke.events(for: bundle)
            XCTAssertEqual(events.map(\.type), [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
            XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [55, 9, 9, 55])
            let leftCommandFlags = CGEventFlags.maskCommand.rawValue | 0x00000008
            XCTAssertEqual(events.map { $0.flags.rawValue }, [leftCommandFlags, leftCommandFlags, leftCommandFlags, 0])
            XCTAssertTrue(events.allSatisfy(PasteKeystroke.isOwnEvent))
        }
    }

    func testLocalPasteKeepsExistingTwoKeyEvents() throws {
        let events = try PasteKeystroke.events(for: "com.apple.TextEdit")
        XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
        XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [9, 9])
        XCTAssertTrue(events.allSatisfy { $0.flags == .maskCommand })
        XCTAssertTrue(events.allSatisfy(PasteKeystroke.isOwnEvent))
    }

    func testOnlyOwnTagIsFilteredAndRightCommandStillRecords() async throws {
        let monitor = GlobalHotKeyMonitor(descriptor: HotKeyDescriptor(keyCode: 54, modifiers: 1_048_576, activationMode: .toggle))
        var presses = 0
        var releases = 0
        let pressed = expectation(description: "Unmarked physical command press")
        let released = expectation(description: "Unmarked physical command release")
        monitor.onPressed = { presses += 1; pressed.fulfill() }
        monitor.onReleased = { releases += 1; released.fulfill() }
        func command(_ down: Bool, tagged: Bool) throws -> CGEvent {
            let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 54, keyDown: down))
            event.type = .flagsChanged
            event.flags = down ? .maskCommand : []
            if tagged { event.setIntegerValueField(.eventSourceUserData, value: PasteKeystroke.eventTag) }
            return event
        }
        let taggedDown = try command(true, tagged: true)
        let taggedUp = try command(false, tagged: true)
        monitor.handle(type: .flagsChanged, event: taggedDown)
        monitor.handle(type: .flagsChanged, event: taggedUp)
        await Task.yield()
        XCTAssertEqual(presses, 0)
        XCTAssertEqual(releases, 0)
        let realDown = try command(true, tagged: false)
        let realUp = try command(false, tagged: false)
        XCTAssertFalse(PasteKeystroke.isOwnEvent(realDown))
        realDown.setIntegerValueField(.eventSourceUserData, value: 42)
        XCTAssertFalse(PasteKeystroke.isOwnEvent(realDown))
        monitor.handle(type: .flagsChanged, event: realDown)
        monitor.handle(type: .flagsChanged, event: realUp)
        await fulfillment(of: [pressed, released], timeout: 1)
        XCTAssertEqual(presses, 1)
        XCTAssertEqual(releases, 1)
    }
}
