import XCTest
@testable import VoiceInput
import VoiceInputCore

@MainActor
final class HotKeyRecorderViewTests: XCTestCase {
    func testRecorderDisplaysArbitraryShortcut() {
        let button = HotKeyRecorderButton()
        button.descriptor = HotKeyDescriptor(keyCode: 2, modifiers: 1_310_720)

        XCTAssertEqual(button.title, "⌃⌘D")
        XCTAssertTrue(button.acceptsFirstResponder)
    }
}
