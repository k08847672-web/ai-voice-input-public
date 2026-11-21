import AVFoundation
import Foundation
import XCTest
@testable import VoiceInput

/// Runs only in the normally signed App test host, with existing microphone permission.
final class MicrophoneHardwareTests: XCTestCase {
    func testActualSelectionProducesPCMWithoutChangingSystemDefault() async throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw XCTSkip("Existing App microphone permission is unavailable; no new permission requested")
        }
        let devices = AudioCaptureService.inputDevices()
        guard !devices.isEmpty else { throw XCTSkip("No physical input is connected") }
        let originalDefault = AudioCaptureService.defaultInputDeviceID()
        let capture = AudioCaptureService()
        defer { capture.stop() }
        // Explicit device, absent-device fallback, then following default on the same service.
        for uid in [devices.first?.uid, "missing-microphone-test-uid", nil] {
            let counter = PacketCounter()
            try capture.start(inputDeviceUID: uid, onAudio: { counter.add($0) }, onLevel: { _ in })
            try await Task.sleep(for: .milliseconds(600))
            capture.stop()
            XCTAssertGreaterThan(counter.byteCount, 0, "Expected live PCM16 packets")
            XCTAssertEqual(AudioCaptureService.defaultInputDeviceID(), originalDefault)
        }
    }

    @MainActor
    func testLocalSampleEarlyStopPlaybackCancelAndAutomaticStop() async throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw XCTSkip("Existing App microphone permission is unavailable; no new permission requested")
        }
        guard !AudioCaptureService.inputDevices().isEmpty else { throw XCTSkip("No physical input is connected") }
        let originalDefault = AudioCaptureService.defaultInputDeviceID()
        let test = MicrophoneTestController()
        defer { test.cancel() }
        await test.start(inputDeviceUID: nil)
        XCTAssertNil(test.error)
        XCTAssertTrue(test.isRecording)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertGreaterThan(test.duration, 0)
        test.stopRecording()
        XCTAssertFalse(test.isRecording)
        XCTAssertTrue(test.hasSample)
        XCTAssertLessThan(test.duration, 5)
        test.play()
        XCTAssertTrue(test.isPlaying)
        try await Task.sleep(for: .milliseconds(100))
        test.cancel()
        XCTAssertFalse(test.isPlaying)
        XCTAssertFalse(test.hasSample)
        XCTAssertEqual(test.duration, 0)
        await test.start(inputDeviceUID: nil)
        try await Task.sleep(for: .milliseconds(5_300))
        XCTAssertFalse(test.isRecording)
        XCTAssertTrue(test.hasSample)
        XCTAssertGreaterThan(test.duration, 0)
        XCTAssertLessThanOrEqual(test.duration, 5)
        test.cancel()
        XCTAssertFalse(test.hasSample)
        XCTAssertEqual(test.level, 0)
        XCTAssertEqual(AudioCaptureService.defaultInputDeviceID(), originalDefault)
    }
}

private final class PacketCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var byteCount: Int { lock.withLock { count } }
    func add(_ packet: Data) { lock.withLock { count += packet.count } }
}
