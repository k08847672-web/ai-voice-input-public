import XCTest
@testable import VoiceInputCore

final class RecognitionSessionStateTests: XCTestCase {
    func testCompleteSessionFlow() throws {
        var state = RecognitionSessionState()
        XCTAssertEqual(try state.apply(.begin), .connecting)
        XCTAssertEqual(try state.apply(.ready), .listening)
        XCTAssertEqual(try state.apply(.partial), .listening)
        XCTAssertEqual(try state.apply(.partial), .listening)
        XCTAssertEqual(try state.apply(.stop), .finalizing)
        XCTAssertEqual(try state.apply(.final), .inserting)
        XCTAssertEqual(try state.apply(.inserted), .idle)
    }

    func testReleaseBeforeReadyStillFinalizes() throws {
        var state = RecognitionSessionState()
        try state.apply(.begin)
        XCTAssertEqual(try state.apply(.stop), .finalizingAwaitingReady)
        XCTAssertEqual(try state.apply(.ready), .finalizing)
        XCTAssertEqual(try state.apply(.partial), .finalizing)
        XCTAssertEqual(try state.apply(.final), .inserting)
    }

    func testFailureCanRetry() throws {
        var state = RecognitionSessionState()
        try state.apply(.begin)
        XCTAssertEqual(try state.apply(.fail), .failed)
        XCTAssertEqual(try state.apply(.begin), .connecting)
    }

    func testCancellationIsIdempotentAndWorksFromEveryPhase() throws {
        for phase in RecognitionPhase.allCasesForTesting {
            var state = RecognitionSessionState(phase: phase)
            XCTAssertEqual(try state.apply(.cancel), .idle)
        }
    }

    func testPartialBeforeReadyIsRejected() throws {
        var state = RecognitionSessionState()
        try state.apply(.begin)
        XCTAssertThrowsError(try state.apply(.partial)) { error in
            XCTAssertEqual(
                error as? RecognitionTransitionError,
                .invalidTransition(from: .connecting, signal: .partial)
            )
        }
    }

    func testFinalBeforeStopIsRejected() throws {
        var state = RecognitionSessionState()
        try state.apply(.begin)
        try state.apply(.ready)
        XCTAssertThrowsError(try state.apply(.final))
    }

    func testDuplicateReadyIsRejected() throws {
        var state = RecognitionSessionState()
        try state.apply(.begin)
        try state.apply(.ready)
        XCTAssertThrowsError(try state.apply(.ready))
    }

    func testInsertedBeforeFinalIsRejected() throws {
        var state = RecognitionSessionState()
        try state.apply(.begin)
        try state.apply(.stop)
        XCTAssertThrowsError(try state.apply(.inserted))
    }

    func testFailureCanBeRecordedBeforeTransportStarts() throws {
        var state = RecognitionSessionState()
        XCTAssertEqual(try state.apply(.fail), .failed)
    }
}

private extension RecognitionPhase {
    static let allCasesForTesting: [RecognitionPhase] = [
        .idle, .connecting, .listening, .finalizingAwaitingReady, .finalizing, .inserting, .failed
    ]
}
