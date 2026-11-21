import XCTest
@testable import VoiceInput
import VoiceInputCore

final class HotKeyInteractionPolicyTests: XCTestCase {
    func testPressAndHoldBeginsOnPressAndEndsOnRelease() {
        XCTAssertEqual(
            HotKeyInteractionPolicy.action(
                activationMode: .pressAndHold,
                signal: .pressed,
                sessionStatus: .ready
            ),
            .begin
        )
        XCTAssertEqual(
            HotKeyInteractionPolicy.action(
                activationMode: .pressAndHold,
                signal: .released,
                sessionStatus: .recording
            ),
            .end
        )
    }

    func testToggleEndsOnlyOnSecondPress() {
        XCTAssertEqual(
            HotKeyInteractionPolicy.action(
                activationMode: .toggle,
                signal: .pressed,
                sessionStatus: .ready
            ),
            .begin
        )
        XCTAssertEqual(
            HotKeyInteractionPolicy.action(
                activationMode: .toggle,
                signal: .released,
                sessionStatus: .recording
            ),
            .none
        )
        XCTAssertEqual(
            HotKeyInteractionPolicy.action(
                activationMode: .toggle,
                signal: .pressed,
                sessionStatus: .recording
            ),
            .end
        )
    }

    func testFinalizingSessionCanBeCancelledWithAnotherPress() {
        for mode in HotKeyActivationMode.allCases {
            XCTAssertEqual(
                HotKeyInteractionPolicy.action(
                    activationMode: mode,
                    signal: .pressed,
                    sessionStatus: .finalizing
                ),
                .cancel
            )
        }
    }

    func testInsertingSessionIgnoresHotKey() {
        for mode in HotKeyActivationMode.allCases {
            XCTAssertEqual(
                HotKeyInteractionPolicy.action(
                    activationMode: mode,
                    signal: .pressed,
                    sessionStatus: .inserting
                ),
                .none
            )
        }
    }
}
