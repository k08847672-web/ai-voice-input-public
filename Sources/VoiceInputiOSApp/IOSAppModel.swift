import AVFoundation
import Combine
import Foundation
import VoiceInputCore
import VoiceInputMobileShared

enum IOSRecognitionState: Equatable {
    case idle
    case requestingPermission
    case connecting
    case listening
    case finalizing
    case completed
    case failed

    var title: String {
        switch self {
        case .idle: "就绪"
        case .requestingPermission: "等待麦克风权限"
        case .connecting: "正在连接识别服务"
        case .listening: "正在录音"
        case .finalizing: "正在生成最终文字"
        case .completed: "文字已准备好"
        case .failed: "本次识别失败"
        }
    }

    var isActive: Bool {
        switch self {
        case .requestingPermission, .connecting, .listening, .finalizing: true
        case .idle, .completed, .failed: false
        }
    }
}

private struct IOSStoredSettings: Codable {
    var serverURL = "ws://100.91.11.111:19001/v1/asr/stream"
    var language = "zh-CN"
    var mode = InputMode.smart
    var allowInsecurePrivateNetwork = false
}

@MainActor
final class IOSAppModel: ObservableObject {
    @Published var state: IOSRecognitionState = .idle
    @Published var serverURL: String
    @Published var language: String
    @Published var mode: InputMode
    @Published var allowInsecurePrivateNetwork: Bool
    @Published var token: String
    @Published var partialTranscript = ""
    @Published var finalTranscript = ""
    @Published var statusMessage = "在主应用中录音，然后回到原应用用语音输入键盘插入。"
    @Published var inputLevel: Float = 0

    private let defaults: UserDefaults
    private let tokenStore: IOSKeychainTokenStore
    private let sharedTranscriptStore: SharedTranscriptStore?
    private let asrClient = WebSocketASRClient()
    private let audioCapture = AudioCaptureService()
    private var sessionState = RecognitionSessionState()
    private var startRequestID: UUID?
    private var activeGeneration: UUID?
    private var audioContinuation: AsyncStream<Data>.Continuation?
    private var audioSendTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var readyTimeoutTask: Task<Void, Never>?
    private var finalTimeoutTask: Task<Void, Never>?
    private var maximumRecordingTask: Task<Void, Never>?

    private static let settingsKey = "ios-settings-v1"

    init(
        defaults: UserDefaults = .standard,
        tokenStore: IOSKeychainTokenStore = IOSKeychainTokenStore(),
        sharedTranscriptStore: SharedTranscriptStore? = SharedTranscriptStore()
    ) {
        self.defaults = defaults
        self.tokenStore = tokenStore
        self.sharedTranscriptStore = sharedTranscriptStore

        let settings: IOSStoredSettings
        if let data = defaults.data(forKey: Self.settingsKey),
           let decoded = try? JSONDecoder().decode(IOSStoredSettings.self, from: data)
        {
            settings = decoded
        } else {
            settings = IOSStoredSettings()
        }
        let previousServerURL = "ws://100.86.28.63:19001/v1/asr/stream"
        if settings.serverURL == previousServerURL {
            var migrated = settings
            migrated.serverURL = "ws://100.91.11.111:19001/v1/asr/stream"
            if let data = try? JSONEncoder().encode(migrated) {
                defaults.set(data, forKey: Self.settingsKey)
            }
            serverURL = migrated.serverURL
        } else {
            serverURL = settings.serverURL
        }
        language = settings.language
        mode = settings.mode
        allowInsecurePrivateNetwork = settings.allowInsecurePrivateNetwork
        do {
            token = try tokenStore.load()
        } catch {
            token = ""
            statusMessage = error.localizedDescription
            state = .failed
        }
    }

    func saveSettings() {
        let normalizedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines)
        let settings = IOSStoredSettings(
            serverURL: normalizedURL,
            language: normalizedLanguage.isEmpty ? "zh-CN" : normalizedLanguage,
            mode: mode,
            allowInsecurePrivateNetwork: allowInsecurePrivateNetwork
        )
        do {
            let data = try JSONEncoder().encode(settings)
            defaults.set(data, forKey: Self.settingsKey)
            try tokenStore.save(token)
            serverURL = settings.serverURL
            language = settings.language
            token = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if state == .failed {
                state = .idle
                statusMessage = "设置已保存"
            }
        } catch {
            state = .failed
            statusMessage = error.localizedDescription
        }
    }

    func startRecording() async {
        guard !state.isActive else { return }
        saveSettings()
        guard state != .failed else { return }

        do {
            _ = try ASRURLValidator.validate(
                serverURL,
                allowInsecurePrivateNetwork: allowInsecurePrivateNetwork
            )
        } catch {
            failBeforeSession(error.localizedDescription)
            return
        }
        guard !token.isEmpty else {
            failBeforeSession("请先输入 ASR Bearer Token；Token 只保存在本机钥匙串。")
            return
        }

        let requestID = UUID()
        startRequestID = requestID
        state = .requestingPermission
        guard await requestMicrophonePermission() else {
            failBeforeSession("未获得麦克风权限，请到系统设置中允许“语音输入法”使用麦克风。")
            return
        }
        guard startRequestID == requestID else { return }
        startRequestID = nil

        let generation = UUID()
        activeGeneration = generation
        sharedTranscriptStore?.clear()
        partialTranscript = ""
        finalTranscript = ""
        inputLevel = 0
        do {
            try sessionState.apply(.begin)
            state = .connecting
            statusMessage = "说话过程中会显示实时识别文字。"
            startReadyTimeout(generation: generation)
            try configureAudioSession()

            let configuration = ASRStartConfiguration(
                language: language,
                mode: mode,
                hotwords: [],
                dictionary: [:],
                style: "",
                sourceApplication: "com.aivoiceinput.ios"
            )
            let events = try await asrClient.start(
                serverURL: serverURL,
                token: token,
                allowInsecurePrivateNetwork: allowInsecurePrivateNetwork,
                configuration: configuration
            )
            guard activeGeneration == generation else { return }
            eventTask = Task { [weak self] in
                await self?.consume(events: events, generation: generation)
            }

            // A fast stop can transition the session while the WebSocket start is suspended.
            guard state == .connecting else { return }
            let (audioStream, continuation) = AsyncStream<Data>.makeStream(
                bufferingPolicy: .bufferingOldest(256)
            )
            audioContinuation = continuation
            audioSendTask = Task { [weak self] in
                guard let self else { return }
                do {
                    for await packet in audioStream {
                        try await self.asrClient.sendAudio(packet)
                    }
                } catch {
                    await self.fail(
                        error.localizedDescription,
                        generation: generation
                    )
                }
            }
            try audioCapture.start(
                onAudio: { [weak self] data in
                    if case .dropped = continuation.yield(data) {
                        Task { @MainActor in
                            await self?.fail("网络发送速度不足，音频缓冲已满", generation: generation)
                        }
                    }
                },
                onLevel: { [weak self] level in
                    Task { @MainActor in
                        guard self?.activeGeneration == generation else { return }
                        self?.inputLevel = level
                    }
                }
            )
            startMaximumRecordingTimeout(generation: generation)
        } catch {
            await fail(error.localizedDescription, generation: generation)
        }
    }

    func stopRecording() async {
        guard state == .connecting || state == .listening,
              let generation = activeGeneration
        else { return }
        do {
            try sessionState.apply(.stop)
        } catch {
            await fail(error.localizedDescription, generation: generation)
            return
        }
        state = .finalizing
        statusMessage = mode == .faithful ? "正在等待识别结果…" : "正在识别并进行 AI 整理…"
        inputLevel = 0
        readyTimeoutTask?.cancel()
        maximumRecordingTask?.cancel()
        startFinalTimeout(generation: generation)
        audioCapture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        _ = await audioSendTask?.result
        guard activeGeneration == generation else { return }
        audioSendTask = nil
        do {
            try await asrClient.finish()
        } catch {
            await fail(error.localizedDescription, generation: generation)
        }
    }

    func cancelRecording() async {
        startRequestID = nil
        let generation = activeGeneration
        await cleanUp(generation: generation, cancelTransport: true)
        try? sessionState.apply(.cancel)
        state = .idle
        partialTranscript = ""
        finalTranscript = ""
        statusMessage = "已取消，未保存音频或转写文字。"
    }

    func clearPreparedTranscript() {
        sharedTranscriptStore?.clear()
        finalTranscript = ""
        partialTranscript = ""
        state = .idle
        statusMessage = "已清除待插入文字。"
    }

    private func consume(events: AsyncStream<ASREvent>, generation: UUID) async {
        for await event in events {
            guard activeGeneration == generation, !Task.isCancelled else { return }
            await handle(event: event, generation: generation)
        }
        guard activeGeneration == generation,
              state == .connecting || state == .listening || state == .finalizing
        else { return }
        await fail(ASRProtocolError.connectionClosed.localizedDescription, generation: generation)
    }

    private func handle(event: ASREvent, generation: UUID) async {
        do {
            switch event {
            case .ready:
                try sessionState.apply(.ready)
                readyTimeoutTask?.cancel()
                if state != .finalizing {
                    state = .listening
                    statusMessage = "正在录音；完成后点击停止。"
                }
            case let .partial(text):
                try sessionState.apply(.partial)
                partialTranscript = text
            case let .final(text):
                try sessionState.apply(.final)
                let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let sharedTranscriptStore,
                      sharedTranscriptStore.publishFinal(normalized)
                else {
                    throw MobileTransferError.publishFailed
                }
                finalTranscript = normalized
                partialTranscript = ""
                try sessionState.apply(.inserted)
                await cleanUp(generation: generation, cancelTransport: false)
                state = .completed
                statusMessage = "请回到刚才的应用，切换到“语音输入”键盘后点击“插入最新文字”。"
            case let .error(_, message):
                await fail(message, generation: generation)
            }
        } catch {
            await fail(error.localizedDescription, generation: generation)
        }
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)
    }

    private func requestMicrophonePermission() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                session.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    private func startReadyTimeout(generation: UUID) {
        readyTimeoutTask?.cancel()
        readyTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled,
                  let self,
                  self.activeGeneration == generation,
                  self.state == .connecting
            else { return }
            await self.fail("连接识别服务超时", generation: generation)
        }
    }

    private func startFinalTimeout(generation: UUID) {
        finalTimeoutTask?.cancel()
        let seconds = mode == .faithful ? 12 : 35
        finalTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled,
                  let self,
                  self.activeGeneration == generation,
                  self.state == .finalizing
            else { return }
            await self.fail("等待最终识别结果超时", generation: generation)
        }
    }

    private func startMaximumRecordingTimeout(generation: UUID) {
        maximumRecordingTask?.cancel()
        maximumRecordingTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled,
                  let self,
                  self.activeGeneration == generation,
                  self.state == .connecting || self.state == .listening
            else { return }
            await self.stopRecording()
        }
    }

    private func failBeforeSession(_ message: String) {
        startRequestID = nil
        state = .failed
        statusMessage = message
    }

    private func fail(_ message: String, generation: UUID?) async {
        guard generation == nil || activeGeneration == generation else { return }
        try? sessionState.apply(.fail)
        await cleanUp(generation: generation, cancelTransport: true)
        state = .failed
        statusMessage = message
        inputLevel = 0
    }

    private func cleanUp(generation: UUID?, cancelTransport: Bool) async {
        if let generation, activeGeneration != generation { return }
        readyTimeoutTask?.cancel()
        finalTimeoutTask?.cancel()
        maximumRecordingTask?.cancel()
        readyTimeoutTask = nil
        finalTimeoutTask = nil
        maximumRecordingTask = nil
        audioCapture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        audioSendTask?.cancel()
        audioSendTask = nil
        if eventTask != nil, !cancelTransport {
            // The receive loop closes itself after final; avoid cancelling the task currently handling it.
        } else {
            eventTask?.cancel()
        }
        eventTask = nil
        if cancelTransport {
            await asrClient.cancel()
        }
        activeGeneration = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

private enum MobileTransferError: LocalizedError {
    case publishFailed

    var errorDescription: String? {
        "无法把最终文字写入 App Group，请检查应用签名与 App Group 配置。"
    }
}
