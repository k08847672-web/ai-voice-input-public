import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Equatable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioCaptureError: LocalizedError {
    case noInputDevice
    case conversionFailed
    case deviceSelectionFailed

    var errorDescription: String? {
        switch self {
        case .noInputDevice: "没有可用的麦克风输入"
        case .conversionFailed: "无法把麦克风音频转换为 16 kHz 单声道 PCM"
        case .deviceSelectionFailed: "无法启用所选麦克风"
        }
    }
}

final class AudioCaptureService: @unchecked Sendable {
    static let sampleRate = 16_000.0
    private var audioUnit: AudioUnit?
    private var captureContext: CaptureContext?
    private let lock = NSLock()
    private var running = false
    private var activeDeviceID: AudioDeviceID?
    private var onInputDisconnected: (@Sendable () -> Void)?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    var onDevicesChanged: (@Sendable () -> Void)?

    init() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.devicesChanged()
        }
        var address = Self.devicesAddress
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, listener
        ) == noErr {
            deviceListener = listener
        }
    }

    deinit {
        if let deviceListener {
            var address = Self.devicesAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, .main, deviceListener
            )
        }
        stop()
    }

    static func inputDevices() -> [AudioInputDevice] {
        var address = devicesAddress
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var identifiers = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = identifiers.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return [] }
        return identifiers.compactMap { id in
            guard hasInputChannels(id),
                  let uid = stringProperty(kAudioDevicePropertyDeviceUID, device: id),
                  let name = stringProperty(kAudioObjectPropertyName, device: id)
            else { return nil }
            guard !isInternalAggregate(uid: uid) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func defaultInputDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var identifier = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout.size(ofValue: identifier))
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &identifier
        ) == noErr else { return AudioDeviceID(kAudioObjectUnknown) }
        return identifier
    }

    static func resolveInputDevice(
        uid: String?, devices: [AudioInputDevice], defaultDeviceID: AudioDeviceID
    ) throws -> AudioInputDevice {
        if let uid, let selected = devices.first(where: { $0.uid == uid }) { return selected }
        guard let device = devices.first(where: { $0.id == defaultDeviceID }) else {
            throw AudioCaptureError.noInputDevice
        }
        return device
    }

    static func isInternalAggregate(uid: String, processID: Int32 = ProcessInfo.processInfo.processIdentifier) -> Bool {
        uid.hasPrefix("CADefaultDeviceAggregate-\(processID)-")
    }

    func start(
        inputDeviceUID: String? = nil,
        onAudio: @escaping @Sendable (Data) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void,
        onInputDisconnected: @escaping @Sendable () -> Void = {}
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }

        let device = try Self.resolveInputDevice(
            uid: inputDeviceUID, devices: Self.inputDevices(), defaultDeviceID: Self.defaultInputDeviceID()
        )
        // An input-only HAL unit owns its device binding. AVAudioEngine's shared I/O
        // rebuilds its default aggregate during prepare(), overwriting explicit devices.
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioCaptureError.deviceSelectionFailed
        }
        var instance: AudioUnit?
        guard AudioComponentInstanceNew(component, &instance) == noErr, let unit = instance else {
            throw AudioCaptureError.deviceSelectionFailed
        }
        do {
            var enabled: UInt32 = 1
            var disabled: UInt32 = 0
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enabled, 4))
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disabled, 4))
            var deviceID = device.id
            try Self.check(AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &deviceID, UInt32(MemoryLayout.size(ofValue: deviceID))
            ))
            var hardwareFormat = AudioStreamBasicDescription()
            var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try Self.check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardwareFormat, &formatSize))
            guard hardwareFormat.mSampleRate > 0, hardwareFormat.mChannelsPerFrame > 0,
                  let inputFormat = AVAudioFormat(
                    standardFormatWithSampleRate: hardwareFormat.mSampleRate,
                    channels: hardwareFormat.mChannelsPerFrame
                  ) else { throw AudioCaptureError.noInputDevice }
            var clientFormat = inputFormat.streamDescription.pointee
            try Self.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &clientFormat, formatSize))
            var maximumFrames: UInt32 = 4_096
            try Self.check(AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximumFrames, 4))
            var framesSize: UInt32 = 4
            try Self.check(AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximumFrames, &framesSize))
            let context = try CaptureContext(
                unit: unit, inputFormat: inputFormat, maximumFrames: maximumFrames,
                onAudio: onAudio, onLevel: onLevel
            )
            var callback = AURenderCallbackStruct(
                inputProc: { reference, flags, timestamp, _, frames, _ in
                    let context = Unmanaged<CaptureContext>.fromOpaque(reference).takeUnretainedValue()
                    return context.render(flags: flags, timestamp: timestamp, frames: frames)
                },
                inputProcRefCon: Unmanaged.passUnretained(context).toOpaque()
            )
            try Self.check(AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                &callback, UInt32(MemoryLayout.size(ofValue: callback))
            ))
            // Retain callback storage until stop + uninitialize have quiesced the unit.
            captureContext = context
            try Self.check(AudioUnitInitialize(unit))
            try Self.check(AudioOutputUnitStart(unit))
            var boundID: AudioDeviceID = 0
            var idSize = UInt32(MemoryLayout<AudioDeviceID>.size)
            try Self.check(AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &boundID, &idSize))
            guard boundID == device.id else { throw AudioCaptureError.deviceSelectionFailed }
            audioUnit = unit
            activeDeviceID = device.id
            self.onInputDisconnected = onInputDisconnected
            running = true
        } catch {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            captureContext = nil
            throw error
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard running, let audioUnit else { return }
        AudioOutputUnitStop(audioUnit)
        AudioUnitUninitialize(audioUnit)
        AudioComponentInstanceDispose(audioUnit)
        self.audioUnit = nil
        captureContext = nil
        activeDeviceID = nil
        onInputDisconnected = nil
        running = false
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw AudioCaptureError.deviceSelectionFailed }
    }

    private final class CaptureContext {
        let unit: AudioUnit
        let buffer: AVAudioPCMBuffer
        let converter: AVAudioConverter
        let outputFormat: AVAudioFormat
        let onAudio: @Sendable (Data) -> Void
        let onLevel: @Sendable (Float) -> Void

        init(unit: AudioUnit, inputFormat: AVAudioFormat, maximumFrames: UInt32,
             onAudio: @escaping @Sendable (Data) -> Void,
             onLevel: @escaping @Sendable (Float) -> Void) throws {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: maximumFrames),
                  let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: AudioCaptureService.sampleRate, channels: 1, interleaved: true),
                  let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw AudioCaptureError.conversionFailed
            }
            self.unit = unit
            self.buffer = buffer
            self.converter = converter
            self.outputFormat = outputFormat
            self.onAudio = onAudio
            self.onLevel = onLevel
        }

        func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, timestamp: UnsafePointer<AudioTimeStamp>, frames: UInt32) -> OSStatus {
            guard frames <= buffer.frameCapacity else { return kAudioUnitErr_TooManyFramesToProcess }
            buffer.frameLength = frames
            let status = AudioUnitRender(unit, flags, timestamp, 1, frames, buffer.mutableAudioBufferList)
            guard status == noErr else { return status }
            if let data = AudioCaptureService.convert(buffer, using: converter, outputFormat: outputFormat), !data.isEmpty {
                onAudio(data)
            }
            onLevel(AudioCaptureService.level(of: buffer))
            return noErr
        }
    }

    private func devicesChanged() {
        let devices = Self.inputDevices()
        let disconnected: (@Sendable () -> Void)? = lock.withLock {
            guard running, let activeDeviceID,
                  !devices.contains(where: { $0.id == activeDeviceID }) else { return nil }
            let callback = onInputDisconnected
            onInputDisconnected = nil
            return callback
        }
        onDevicesChanged?()
        disconnected?()
    }

    private static var devicesAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func hasInputChannels(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { return false }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage) == noErr else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        let value = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
        value.initialize(to: nil)
        defer {
            value.deinitialize(count: 1)
            value.deallocate()
        }
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee as String?
    }

    private static func convert(
        _ input: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        outputFormat: AVAudioFormat
    ) -> Data? {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var conversionError: NSError?
        var suppliedInput = false
        let status = converter.convert(to: output, error: &conversionError) { _, status in
            if suppliedInput {
                status.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            status.pointee = .haveData
            return input
        }
        guard conversionError == nil, status != .error else { return nil }
        let buffer = output.audioBufferList.pointee.mBuffers
        guard let bytes = buffer.mData, buffer.mDataByteSize > 0 else { return nil }
        return Data(bytes: bytes, count: Int(buffer.mDataByteSize))
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let samples = channels[0]
        var sum: Float = 0
        for index in 0 ..< Int(buffer.frameLength) {
            sum += samples[index] * samples[index]
        }
        return min(1, sqrt(sum / Float(buffer.frameLength)) * 4)
    }
}

