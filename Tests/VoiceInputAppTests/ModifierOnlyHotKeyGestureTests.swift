import XCTest
@testable import VoiceInput
import VoiceInputCore

final class ModifierOnlyHotKeyGestureTests: XCTestCase {
    func testPhysicalKeyStateAlternatesMatchingCommandEventsWithoutPollingGlobalState() {
        var state = ModifierOnlyPhysicalKeyState()

        XCTAssertEqual(state.matchingFlagsChanged(), .down)
        XCTAssertTrue(state.isDown)
        XCTAssertEqual(state.matchingFlagsChanged(), .up)
        XCTAssertFalse(state.isDown)
    }

    func testPhysicalKeyStateIgnoresReleaseWhenMonitorStartsWhileCommandIsHeld() {
        var state = ModifierOnlyPhysicalKeyState()
        state.reset(currentlyDown: true)

        XCTAssertNil(state.matchingFlagsChanged())
        XCTAssertFalse(state.isDown)
        XCTAssertEqual(state.matchingFlagsChanged(), .down)
    }

    func testPhysicalKeyStateResetAfterTapRecoveryIgnoresHeldKeyRelease() {
        var state = ModifierOnlyPhysicalKeyState()
        XCTAssertEqual(state.matchingFlagsChanged(), .down)

        state.reset(currentlyDown: true)

        XCTAssertNil(state.matchingFlagsChanged())
        XCTAssertFalse(state.isDown)
    }

    func testHoldStartsAfterDelayAndEndsOnRelease() {
        var gesture = ModifierOnlyHotKeyGesture()

        XCTAssertEqual(
            gesture.modifierDown(activationMode: .pressAndHold),
            [.scheduleHoldActivation]
        )
        XCTAssertEqual(gesture.activationDelayElapsed(), [.pressed])
        XCTAssertEqual(gesture.modifierUp(), [.released])
    }

    func testCommandChordCancelsPendingHold() {
        var gesture = ModifierOnlyHotKeyGesture()

        _ = gesture.modifierDown(activationMode: .pressAndHold)
        XCTAssertEqual(gesture.otherKeyPressed(), [.cancelHoldActivation])
        XCTAssertEqual(gesture.activationDelayElapsed(), [])
        XCTAssertEqual(gesture.modifierUp(), [])
    }

    func testCommandChordCancelsActiveHold() {
        var gesture = ModifierOnlyHotKeyGesture()

        _ = gesture.modifierDown(activationMode: .pressAndHold)
        _ = gesture.activationDelayElapsed()
        XCTAssertEqual(gesture.otherKeyPressed(), [.cancelled])
        XCTAssertEqual(gesture.modifierUp(), [])
    }

    func testToggleTriggersOnlyForCommandTapWithoutChord() {
        var gesture = ModifierOnlyHotKeyGesture()

        XCTAssertEqual(gesture.modifierDown(activationMode: .toggle), [])
        XCTAssertEqual(gesture.modifierUp(), [.tapped])

        XCTAssertEqual(gesture.modifierDown(activationMode: .toggle), [])
        XCTAssertEqual(gesture.otherKeyPressed(), [])
        XCTAssertEqual(gesture.modifierUp(), [])
    }

    func testRecorderWaitsForCommandReleaseBeforeRecordingModifierOnlyShortcut() {
        var gesture = ModifierOnlyHotKeyRecorderGesture()

        XCTAssertNil(gesture.commandChanged(keyCode: 55))
        XCTAssertEqual(gesture.commandChanged(keyCode: 55), 55)
    }

    func testRecorderRecordsRightCommandWithoutPollingGlobalKeyState() {
        var gesture = ModifierOnlyHotKeyRecorderGesture()

        XCTAssertNil(gesture.commandChanged(keyCode: 54))
        XCTAssertEqual(gesture.commandChanged(keyCode: 54), 54)
    }

    func testRecorderDoesNotTreatBothCommandKeysAsOneBareCommand() {
        var gesture = ModifierOnlyHotKeyRecorderGesture()

        XCTAssertNil(gesture.commandChanged(keyCode: 54))
        XCTAssertNil(gesture.commandChanged(keyCode: 55))
        XCTAssertNil(gesture.commandChanged(keyCode: 55))
        XCTAssertNil(gesture.commandChanged(keyCode: 54))
    }

    func testRecorderLeavesCommandChordAvailableForNormalKeyCapture() {
        var gesture = ModifierOnlyHotKeyRecorderGesture()

        XCTAssertNil(gesture.commandChanged(keyCode: 55))
        gesture.nonModifierKeyPressed()
        XCTAssertNil(gesture.commandChanged(keyCode: 55))
    }

    func testRecorderDoesNotTreatModifierChordAsBareCommand() {
        var gesture = ModifierOnlyHotKeyRecorderGesture()

        XCTAssertNil(gesture.commandChanged(keyCode: 55))
        gesture.otherModifierChanged()
        XCTAssertNil(gesture.commandChanged(keyCode: 55))
    }
}
