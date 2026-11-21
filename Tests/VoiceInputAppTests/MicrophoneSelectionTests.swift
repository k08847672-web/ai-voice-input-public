import AVFoundation
import Foundation
import XCTest
import VoiceInputCore
@testable import VoiceInput

final class MicrophoneSelectionTests: XCTestCase {
    private let builtIn = AudioInputDevice(id: 12, uid: "built-in", name: "Built-in")
    private let usb = AudioInputDevice(id: 34, uid: "usb-mic", name: "USB")

    func testOnlyThisProcessInternalDefaultAggregateIsFiltered() {
        XCTAssertTrue(AudioCaptureService.isInternalAggregate(uid: "CADefaultDeviceAggregate-123-0", processID: 123))
        XCTAssertFalse(AudioCaptureService.isInternalAggregate(uid: "CADefaultDeviceAggregate-124-0", processID: 123))
        XCTAssertFalse(AudioCaptureService.isInternalAggregate(uid: "MyAggregateDevice", processID: 123))
        XCTAssertFalse(AudioCaptureService.isInternalAggregate(uid: "virtual-microphone", processID: 123))
        XCTAssertFalse(AudioCaptureService.isInternalAggregate(uid: "BuiltInMicrophoneDevice", processID: 123))
    }

    func testFollowDefaultAndExplicitSelection() throws {
        let devices = [builtIn, usb]
        XCTAssertEqual(try AudioCaptureService.resolveInputDevice(
            uid: nil, devices: devices, defaultDeviceID: builtIn.id
        ), builtIn)
        XCTAssertEqual(try AudioCaptureService.resolveInputDevice(
            uid: usb.uid, devices: devices, defaultDeviceID: builtIn.id
        ), usb)
    }

    func testMissingSelectionFallsBackAndReconnectUsesPersistentUID() throws {
        let savedUID = usb.uid
        XCTAssertEqual(try AudioCaptureService.resolveInputDevice(
            uid: savedUID, devices: [builtIn], defaultDeviceID: builtIn.id
        ), builtIn)
        let reconnected = AudioInputDevice(id: 99, uid: savedUID, name: "USB")
        XCTAssertEqual(try AudioCaptureService.resolveInputDevice(
            uid: savedUID, devices: [builtIn, reconnected], defaultDeviceID: builtIn.id
        ), reconnected)
    }

    func testNoInputUsesExistingError() {
        XCTAssertThrowsError(try AudioCaptureService.resolveInputDevice(
            uid: nil, devices: [], defaultDeviceID: 0
        )) { error in
            guard case AudioCaptureError.noInputDevice = error else {
                return XCTFail("Expected the existing no-input error")
            }
        }
    }

    func testLegacyDocumentWithoutMicrophoneSelectionStillLoads() throws {
        let settings = AppSettings()
        let oldDocument = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "settings": JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))
        ])
        let decoded = try JSONDecoder().decode(SettingsDocument.self, from: oldDocument)
        XCTAssertNil(decoded.microphoneDeviceUID)
        XCTAssertEqual(decoded.settings, settings)
    }

    func testEncryptedSelectionRoundTripPreservesOtherSettings() throws {
        var keyData: Data?
        let codec = SecureSettingsCodec(loadKeyData: { keyData }, saveKeyData: { keyData = $0 })
        var settings = AppSettings()
        settings.serverURL = "ws://192.168.1.10:19001/v1/asr/stream"
        settings.language = "en"
        settings.hotwords = ["Microphone test"]
        let document = SettingsDocument(schemaVersion: 1, settings: settings, microphoneDeviceUID: usb.uid)
        let encoded = try JSONEncoder().encode(document)
        let encrypted = try codec.encrypt(encoded)
        XCTAssertNotEqual(encrypted, encoded)
        let decoded = try JSONDecoder().decode(SettingsDocument.self, from: codec.decrypt(encrypted))
        XCTAssertEqual(decoded.microphoneDeviceUID, usb.uid)
        XCTAssertEqual(decoded.settings, settings)
    }

    func testShortSampleIsBoundedAndWaveHeaderMatchesPCM() throws {
        var sample = MicrophoneTestSample()
        sample.append(Data(repeating: 0x12, count: 32_000))
        XCTAssertEqual(sample.duration, 1)
        sample.append(Data(repeating: 0x34, count: 200_000))
        XCTAssertTrue(sample.isFull)
        XCTAssertEqual(sample.pcm.count, 160_000)
        sample.append(Data(repeating: 0x56, count: 100))
        XCTAssertEqual(sample.pcm.count, 160_000)
        let wave = sample.waveData()
        XCTAssertEqual(wave.count, 160_044)
        XCTAssertEqual(String(data: wave.prefix(4), encoding: .utf8), "RIFF")
        XCTAssertEqual(String(data: wave[8..<16], encoding: .utf8), "WAVEfmt ")
        XCTAssertEqual(wave.suffix(160_000), sample.pcm)
        let player = try AVAudioPlayer(data: wave)
        XCTAssertEqual(player.duration, 5, accuracy: 0.001)
        XCTAssertEqual(player.numberOfChannels, 1)
        XCTAssertFalse(player.isPlaying)
    }

    func testEarlyStopSampleAndEmptyCancellationReleaseMemory() {
        var sample = MicrophoneTestSample()
        sample.append(Data(repeating: 0, count: 16_001))
        XCTAssertEqual(sample.pcm.count, 16_000)
        XCTAssertEqual(sample.duration, 0.5)
        XCTAssertFalse(sample.isFull)
        sample = MicrophoneTestSample()
        XCTAssertTrue(sample.pcm.isEmpty)
        XCTAssertEqual(sample.duration, 0)
    }
}
