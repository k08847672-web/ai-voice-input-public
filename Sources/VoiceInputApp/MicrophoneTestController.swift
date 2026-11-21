import AVFoundation
import Foundation

/// A short PCM16 sample held only in memory, never sent to the recognition client.
struct MicrophoneTestSample {
    static let maximumDuration = 5.0
    static let bytesPerSecond = 32_000
    private(set) var pcm = Data()

    var duration: Double { Double(pcm.count) / Double(Self.bytesPerSecond) }
    var isFull: Bool { pcm.count == Int(Self.maximumDuration) * Self.bytesPerSecond }

    mutating func append(_ packet: Data) {
        let remaining = Int(Self.maximumDuration) * Self.bytesPerSecond - pcm.count
        pcm.append(packet.prefix(min(remaining, packet.count) / 2 * 2))
    }

    func waveData() -> Data {
        var result = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { result.append(contentsOf: $0) }
        }
        append(UInt32(36 + pcm.count))
        result.append(Data("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(16_000))
        append(UInt32(Self.bytesPerSecond))
        append(UInt16(2))
        append(UInt16(16))
        result.append(Data("data".utf8))
        append(UInt32(pcm.count))
        result.append(pcm)
        return result
    }
}

@MainActor
final class MicrophoneTestController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPreparing = false
    @Published private(set) var isRecording = false
    @Published private(set) var isPlaying = false
    @Published private(set) var level: Float = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var error: String?

    var hasSample: Bool { duration > 0 }
    private let capture = AudioCaptureService()
    private var sample = MicrophoneTestSample()
    private var player: AVAudioPlayer?
    private var generation: UUID?
    private var stopTask: Task<Void, Never>?

    func start(inputDeviceUID: String?) async {
        cancel()
        let generation = UUID()
        self.generation = generation
        isPreparing = true
        let allowed = await PermissionService.requestMicrophone()
        guard self.generation == generation else { return }
        isPreparing = false
        guard allowed else {
            error = "请先授予麦克风权限"
            return
        }
        do {
            try capture.start(
                inputDeviceUID: inputDeviceUID,
                onAudio: { [weak self] packet in
                    Task { @MainActor in self?.receive(packet, generation: generation) }
                },
                onLevel: { [weak self] level in
                    Task { @MainActor in
                        guard let self, self.generation == generation, self.isRecording else { return }
                        self.level = level
                    }
                },
                onInputDisconnected: { [weak self] in
                    Task { @MainActor in
                        guard let self, self.generation == generation else { return }
                        self.stopRecording()
                        self.error = "麦克风已断开，已停止测试"
                    }
                }
            )
            isRecording = true
            stopTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(MicrophoneTestSample.maximumDuration))
                guard !Task.isCancelled, self?.generation == generation else { return }
                self?.stopRecording()
            }
        } catch {
            self.error = error.localizedDescription
            self.generation = nil
        }
    }

    func stopRecording() {
        generation = nil
        stopTask?.cancel()
        stopTask = nil
        capture.stop()
        isPreparing = false
        isRecording = false
        level = 0
        if !hasSample { error = "未收到麦克风音频，请检查设备后重试" }
    }

    func play() {
        guard hasSample, !isRecording, !isPreparing else { return }
        stopPlayback()
        error = nil
        do {
            let player = try AVAudioPlayer(data: sample.waveData())
            player.delegate = self
            self.player = player
            guard player.play() else {
                self.player = nil
                error = "无法回放测试录音"
                return
            }
            isPlaying = true
        } catch {
            self.error = "无法回放测试录音：\(error.localizedDescription)"
        }
    }

    func stopPlayback() {
        player?.delegate = nil
        player?.stop()
        player = nil
        isPlaying = false
    }

    func cancel() {
        generation = nil
        stopTask?.cancel()
        stopTask = nil
        capture.stop()
        stopPlayback()
        sample = MicrophoneTestSample()
        isPreparing = false
        isRecording = false
        level = 0
        duration = 0
        error = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identifier = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let currentPlayer = self.player,
                  ObjectIdentifier(currentPlayer) == identifier else { return }
            self.stopPlayback()
            if !flag { self.error = "测试录音回放未完成" }
        }
    }

    private func receive(_ packet: Data, generation: UUID) {
        guard self.generation == generation, isRecording else { return }
        sample.append(packet)
        duration = sample.duration
        if sample.isFull { stopRecording() }
    }
}
