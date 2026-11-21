import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import VoiceInputCore

enum InputState: Equatable {
    case idle
    case connecting
    case listening
    case finalizing
    case inserting
    case error(String)

    var label: String {
        switch self {
        case .idle: "就绪"
        case .connecting: "正在连接识别服务"
        case .listening: "正在聆听"
        case .finalizing: "正在整理文字"
        case .inserting: "正在插入文字"
        case let .error(message): message
        }
    }

    var symbol: String {
        switch self {
        case .idle: "waveform"
        case .connecting, .finalizing, .inserting: "ellipsis.circle"
        case .listening: "waveform.circle.fill"
        case .error: "exclamationmark.triangle"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    private static let inputMonitoringRequiredMessage = "请先授予输入监控权限"

    @Published private(set) var state: InputState = .idle
    @Published private(set) var partialTranscript = ""
    @Published private(set) var permissionSnapshot = PermissionService.snapshot()
    @Published private(set) var serverTestMessage: String?
    @Published private(set) var isTestingServer = false
    @Published private(set) var recoverableTranscript: String?
    @Published private(set) var inputDevices = AudioCaptureService.inputDevices()
    @Published private(set) var dictionaryRecordingID: UUID?
    @Published private(set) var dictionaryRecordingMessage: String?
    @Published private(set) var dictionarySyncMessage = "词典同步尚未连接"

    let settingsStore = SettingsStore()
    let microphoneTest = MicrophoneTestController()
    let diagnostics = DiagnosticsStore()
    let overlayState = OverlayState()

    private let asrClient = WebSocketASRClient()
    private let audioCapture = AudioCaptureService()
    private let hotKeyMonitor = GlobalHotKeyMonitor()
    private let textInsertion = TextInsertionService()
    private let clock = ContinuousClock()
    private var sessionState = RecognitionSessionState()
    private lazy var overlayController = OverlayWindowController(state: overlayState)

    private var eventTask: Task<Void, Never>?
    private var audioSendTask: Task<Void, Never>?
    private var audioContinuation: AsyncStream<Data>.Continuation?
    private var readyTimeoutTask: Task<Void, Never>?
    private var maximumSessionTask: Task<Void, Never>?
    private var finalTimeoutTask: Task<Void, Never>?
    private var activeBundleIdentifier: String?
    private var activeInputMode: InputMode?
    private var activeTextInsertionTarget: TextInsertionTarget?
    private var sessionStartedAt: ContinuousClock.Instant?
    private var firstPartialAt: ContinuousClock.Instant?
    private var stopRequestedAt: ContinuousClock.Instant?
    private var activationObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var activeSessionGeneration: UUID?
    private var hotKeyIsPressed = false
    private var activePressMode: HotKeyActivationMode?
    private var hotKeyBeginRequestID: UUID?
    private var dictionarySyncLoop: Task<Void, Never>?
    private var isSyncingDictionary = false
    private var started = false

    init() {
        audioCapture.onDevicesChanged = { [weak self] in
            Task { @MainActor in self?.refreshInputDevices() }
        }
        hotKeyMonitor.onPressed = { [weak self] in
            Task { @MainActor in await self?.handleHotKeyPressed() }
        }
        hotKeyMonitor.onReleased = { [weak self] in
            Task { @MainActor in await self?.handleHotKeyReleased() }
        }
        hotKeyMonitor.onCancelled = { [weak self] in
            Task { @MainActor in await self?.handleHotKeyCancelled() }
        }
        hotKeyMonitor.onEscape = { [weak self] in
            guard let self, case .error = self.state else { return }
            self.overlayController.hide()
        }
        start()
    }

    func start() {
        guard !started else { return }
        started = true
        refreshPermissions()
        configureHotKey()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPermissions()
                await self?.syncDictionary()
            }
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.prepareForTermination()
            }
        }
        diagnostics.record("app_started")
        dictionarySyncLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncDictionary()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func shutdown() async {
        microphoneTest.cancel()
        dictionarySyncLoop?.cancel()
        dictionarySyncLoop = nil
        hotKeyBeginRequestID = nil
        await cleanUpSession()
        hotKeyMonitor.stop()
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
        recoverableTranscript = nil
        settingsStore.flush()
        diagnostics.record("app_stopped")
    }

    func refreshPermissions() {
        refreshInputDevices()
        let wasMonitoring = permissionSnapshot.inputMonitoring
        permissionSnapshot = PermissionService.snapshot()
        if started, !wasMonitoring, permissionSnapshot.inputMonitoring {
            configureHotKey()
        }
    }

    func refreshInputDevices() {
        inputDevices = AudioCaptureService.inputDevices()
    }

    func syncDictionary() async {
        guard !isSyncingDictionary, !settingsStore.requiresSettingsReset else { return }
        let settings = settingsStore.settings
        let url: URL
        do {
            url = try DictionarySyncURL.fromASR(
                settings.serverURL,
                allowInsecurePrivateNetwork: settings.allowInsecurePrivateNetwork
            )
        } catch {
            dictionarySyncMessage = "词典同步需要标准 v1 私网入口"
            return
        }
        let token = settingsStore.authorizationToken
        guard !token.isEmpty else {
            dictionarySyncMessage = "配置识别服务令牌后自动同步词典"
            return
        }
        isSyncingDictionary = true
        defer { isSyncingDictionary = false }
        let client = DictionarySyncHTTPClient(url: url, token: token)
        do {
            for _ in 0 ..< 3 {
                let remote = try await client.fetch()
                let baseline = settingsStore.dictionarySyncBaseline?.entries ?? [:]
                let local = try settingsStore.completeDictionaryEntries()
                let merged = DictionarySyncMerge.merge(
                    baseline: baseline, local: local, remote: remote.entries
                )
                if merged.entries == remote.entries {
                    let latest = try settingsStore.completeDictionaryEntries()
                    let current = DictionarySyncMerge.merge(
                        baseline: local, local: latest, remote: remote.entries
                    )
                    settingsStore.applyDictionarySync(remote, merged: current.entries)
                    dictionarySyncMessage = merged.conflicts.isEmpty ? "词典已同步" : "同一读音有冲突，已保留本机修改"
                    return
                }
                let proposed = DictionarySyncSnapshot(
                    revision: remote.revision, entries: merged.entries
                )
                guard let saved = try await client.replace(proposed) else { continue }
                let latest = try settingsStore.completeDictionaryEntries()
                let current = DictionarySyncMerge.merge(
                    baseline: local, local: latest, remote: saved.entries
                )
                settingsStore.applyDictionarySync(saved, merged: current.entries)
                dictionarySyncMessage = merged.conflicts.isEmpty ? "词典已同步" : "同一读音有冲突，已保留本机修改"
                return
            }
            dictionarySyncMessage = "词典正在被其他设备更新，稍后重试"
        } catch {
            dictionarySyncMessage = error.localizedDescription
        }
    }

    private var hotKeySessionStatus: HotKeySessionStatus {
        switch state {
        case .idle, .error: .ready
        case .connecting, .listening: .recording
        case .finalizing: .finalizing
        case .inserting: .inserting
        }
    }

    private func handleHotKeyPressed() async {
        guard dictionaryRecordingID == nil else { return }
        let activationMode = settingsStore.settings.hotKey.activationMode
        hotKeyIsPressed = true
        activePressMode = activationMode
        let action = HotKeyInteractionPolicy.action(
            activationMode: activationMode,
            signal: .pressed,
            sessionStatus: hotKeySessionStatus
        )
        switch action {
        case .begin:
            let requestID = UUID()
            hotKeyBeginRequestID = requestID
            await beginInput()
            guard hotKeyBeginRequestID == requestID else { return }
            hotKeyBeginRequestID = nil
            // Permission prompts and network setup can outlive a quick key press.
            // In hold mode, honor a release that happened while beginInput was suspended.
            if activationMode == .pressAndHold, !hotKeyIsPressed {
                await endInput()
            }
        case .end:
            await endInput()
        case .cancel:
            await cancelInput()
        case .none:
            break
        }
    }

    private func handleHotKeyReleased() async {
        guard dictionaryRecordingID == nil else { return }
        hotKeyIsPressed = false
        let activationMode = activePressMode ?? settingsStore.settings.hotKey.activationMode
        activePressMode = nil
        let action = HotKeyInteractionPolicy.action(
            activationMode: activationMode,
            signal: .released,
            sessionStatus: hotKeySessionStatus
        )
        if action == .end { await endInput() }
    }

    private func handleHotKeyCancelled() async {
        guard dictionaryRecordingID == nil else { return }
        hotKeyIsPressed = false
        activePressMode = nil
        hotKeyBeginRequestID = nil
        await cancelInput()
    }

    func requestMicrophonePermission() async {
        let granted = await PermissionService.requestMicrophone()
        refreshPermissions()
        if !granted { PermissionService.openSystemSettings(.microphone) }
    }

    func requestAccessibilityPermission() {
        let granted = PermissionService.requestAccessibility()
        refreshPermissions()
        if !granted { PermissionService.openSystemSettings(.accessibility) }
    }

    func requestInputMonitoringPermission() {
        let granted = PermissionService.requestInputMonitoring()
        refreshPermissions()
        if !granted { PermissionService.openSystemSettings(.inputMonitoring) }
        configureHotKey()
    }

    var canConfigureHotKey: Bool {
        switch state {
        case .idle, .error: true
        case .connecting, .listening, .finalizing, .inserting: false
        }
    }

    var canStartDictionaryPronunciation: Bool {
        guard dictionaryRecordingID == nil, !isTestingServer else { return false }
        switch state {
        case .idle, .error: return true
        case .connecting, .listening, .finalizing, .inserting: return false
        }
    }

    func suspendHotKeyForRecording() {
        hotKeyMonitor.stop()
        hotKeyIsPressed = false
        activePressMode = nil
        hotKeyBeginRequestID = nil
    }

    func configureHotKey() {
        hotKeyMonitor.stop()
        guard PermissionService.snapshot().inputMonitoring else {
            state = .error(Self.inputMonitoringRequiredMessage)
            diagnostics.record(.warning, "hotkey_permission_missing")
            return
        }
        do {
            try hotKeyMonitor.start(descriptor: settingsStore.settings.hotKey)
            if state == .error(Self.inputMonitoringRequiredMessage) { state = .idle }
            diagnostics.record("hotkey_started")
        } catch {
            state = .error(error.localizedDescription)
            diagnostics.record(.error, "hotkey_start_failed")
        }
    }

    func beginInput() async {
        microphoneTest.cancel()
        await beginRecognition(dictionaryID: nil)
    }

    func beginDictionaryPronunciation(for id: UUID) async {
        guard settingsStore.settings.dictionary.contains(where: { $0.id == id }) else { return }
        await beginRecognition(dictionaryID: id)
    }

    private func beginRecognition(dictionaryID: UUID?) async {
        guard !isTestingServer else { return }
        switch state {
        case .idle, .error: break
        case .connecting, .listening, .finalizing, .inserting: return
        }

        if let dictionaryID {
            dictionaryRecordingID = dictionaryID
            dictionaryRecordingMessage = "正在准备录音…"
            guard await PermissionService.requestMicrophone() else {
                refreshPermissions()
                dictionaryRecordingID = nil
                dictionaryRecordingMessage = "请先授权麦克风"
                return
            }
            refreshPermissions()
        } else {
            guard await ensurePermissions() else { return }
            do {
                activeTextInsertionTarget = try textInsertion.captureTarget()
            } catch {
                await fail(error.localizedDescription, event: "input_target_rejected")
                return
            }
        }
        recoverableTranscript = nil
        partialTranscript = ""
        activeBundleIdentifier = activeTextInsertionTarget.flatMap {
            NSRunningApplication(processIdentifier: $0.processIdentifier)?.bundleIdentifier
        }
        let profile = dictionaryID == nil
            ? settingsStore.settings.resolvedProfile(for: activeBundleIdentifier)
            : (mode: InputMode.faithful, style: "")
        activeInputMode = profile.mode
        let dictionary = settingsStore.settings.dictionary.reduce(into: [String: String]()) { result, entry in
            if dictionaryID == nil, !entry.spoken.isEmpty { result[entry.spoken] = entry.written }
        }
        let configuration = ASRStartConfiguration(
            language: settingsStore.settings.language,
            mode: profile.mode,
            hotwords: dictionaryID == nil ? settingsStore.settings.hotwords : [],
            dictionary: dictionary,
            style: profile.style,
            sourceApplication: dictionaryID == nil ? activeBundleIdentifier : Bundle.main.bundleIdentifier
        )

        do {
            try sessionState.apply(.begin)
        } catch {
            await fail(error.localizedDescription, event: "session_transition_failed")
            return
        }
        let microphoneDeviceUID = settingsStore.microphoneDeviceUID
        let generation = UUID()
        activeSessionGeneration = generation
        state = .connecting
        sessionStartedAt = clock.now
        firstPartialAt = nil
        stopRequestedAt = nil
        if dictionaryID == nil {
            updateOverlay(title: "正在连接", transcript: "", recording: true, visible: true)
        }
        diagnostics.record("recognition_start", fields: [
            "mode": profile.mode.rawValue,
            "source_application": activeBundleIdentifier ?? "unknown"
        ])
        startReadyTimeout(generation: generation)

        do {
            let events = try await asrClient.start(
                serverURL: settingsStore.settings.serverURL,
                token: settingsStore.authorizationToken,
                allowInsecurePrivateNetwork: settingsStore.settings.allowInsecurePrivateNetwork,
                configuration: configuration
            )
            guard activeSessionGeneration == generation else { return }
            eventTask = Task { [weak self] in
                for await event in events {
                    guard !Task.isCancelled else { break }
                    await self?.handle(event, generation: generation)
                }
            }

            // A quick key release can finalize the session while start() is suspended.
            // Keep consuming its events, but never start recording after that transition.
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
                        event: "audio_send_failed",
                        generation: generation
                    )
                }
            }
            try audioCapture.start(
                inputDeviceUID: microphoneDeviceUID,
                onAudio: { [weak self] data in
                    if case .dropped = continuation.yield(data) {
                        Task { @MainActor in
                            await self?.fail(
                                "网络发送速度不足，音频缓冲已满",
                                event: "audio_buffer_overflow",
                                generation: generation
                            )
                        }
                    }
                },
                onLevel: { [weak self] level in
                    Task { @MainActor in self?.overlayState.level = level }
                },
                onInputDisconnected: { [weak self] in
                    Task { @MainActor in
                        guard self?.activeSessionGeneration == generation else { return }
                        await self?.endInput()
                    }
                }
            )
            startMaximumSessionTimeout(generation: generation)
            if dictionaryID != nil { dictionaryRecordingMessage = "正在录音，点停止后填入读音" }
            if settingsStore.settings.playSounds { NSSound(named: "Tink")?.play() }
        } catch {
            guard activeSessionGeneration == generation else { return }
            await fail(
                error.localizedDescription,
                event: "recognition_start_failed",
                generation: generation
            )
        }
    }

    func endInput() async {
        guard state == .connecting || state == .listening,
              let generation = activeSessionGeneration
        else { return }
        do {
            try sessionState.apply(.stop)
        } catch {
            await fail(
                error.localizedDescription,
                event: "session_transition_failed",
                generation: generation
            )
            return
        }
        state = .finalizing
        stopRequestedAt = clock.now
        if dictionaryRecordingID != nil {
            dictionaryRecordingMessage = "正在识别读音…"
        } else {
            updateOverlay(
                title: finalizingTitle,
                transcript: partialTranscript,
                recording: false,
                visible: true
            )
        }
        startFinalTimeout(generation: generation)
        audioCapture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        _ = await audioSendTask?.result
        guard activeSessionGeneration == generation else { return }
        audioSendTask = nil
        do {
            try await asrClient.finish()
            guard activeSessionGeneration == generation else { return }
        } catch {
            await fail(
                error.localizedDescription,
                event: "recognition_finish_failed",
                generation: generation
            )
        }
    }

    func cancelInput() async {
        hotKeyBeginRequestID = nil
        guard state != .inserting else { return }
        let wasDictionaryRecording = dictionaryRecordingID != nil
        let generation = activeSessionGeneration
        await cleanUpSession(expectedGeneration: generation)
        try? sessionState.apply(.cancel)
        state = .idle
        partialTranscript = ""
        recoverableTranscript = nil
        overlayController.hide()
        if wasDictionaryRecording { dictionaryRecordingMessage = "已取消录音" }
        diagnostics.record("recognition_cancelled")
    }

    func copyRecoverableTranscript() {
        guard let recoverableTranscript else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(recoverableTranscript, forType: .string) else {
            state = .error("无法复制识别文字")
            diagnostics.record(.error, "recovered_transcript_copy_failed")
            return
        }
        state = .error("识别文字已复制，可手动粘贴")
        updateOverlay(
            title: "文字已复制",
            transcript: "请在目标位置手动粘贴",
            recording: false,
            visible: true
        )
        diagnostics.record("recovered_transcript_copied")
    }

    func testServer() async {
        guard state == .idle, !isTestingServer else {
            serverTestMessage = "请先结束当前识别"
            return
        }
        isTestingServer = true
        defer { isTestingServer = false }
        serverTestMessage = "正在连接…"
        let settings = settingsStore.settings
        let configuration = ASRStartConfiguration(
            language: settings.language,
            mode: .faithful,
            hotwords: [],
            dictionary: [:],
            style: "",
            sourceApplication: Bundle.main.bundleIdentifier
        )
        do {
            let stream = try await asrClient.start(
                serverURL: settings.serverURL,
                token: settingsStore.authorizationToken,
                allowInsecurePrivateNetwork: settings.allowInsecurePrivateNetwork,
                configuration: configuration
            )
            let event = await firstEvent(from: stream, timeout: .seconds(5))
            await asrClient.cancel()
            switch event {
            case .ready?:
                serverTestMessage = "连接成功"
            case let .error(_, message)?:
                serverTestMessage = message
            default:
                serverTestMessage = "服务未在 5 秒内确认连接"
            }
        } catch {
            await asrClient.cancel()
            serverTestMessage = error.localizedDescription
        }
    }

    private func ensurePermissions() async -> Bool {
        let microphone = await PermissionService.requestMicrophone()
        let accessibility = AXIsProcessTrusted()
        let inputMonitoring = CGPreflightListenEventAccess()
        refreshPermissions()
        guard microphone, accessibility, inputMonitoring else {
            state = .error("请先授予麦克风、辅助功能和输入监控权限")
            diagnostics.record(.warning, "recognition_permissions_missing")
            return false
        }
        return true
    }

    private func handle(_ event: ASREvent, generation: UUID) async {
        guard activeSessionGeneration == generation else { return }
        switch event {
        case .ready:
            readyTimeoutTask?.cancel()
            readyTimeoutTask = nil
            do {
                try sessionState.apply(.ready)
            } catch {
                await fail(
                    error.localizedDescription,
                    event: "protocol_event_out_of_order",
                    generation: generation
                )
                return
            }
            if let sessionStartedAt {
                diagnostics.record("asr_ready", fields: [
                    "latency_ms": Self.milliseconds(sessionStartedAt.duration(to: clock.now))
                ])
            }
            if state == .connecting {
                state = .listening
                if dictionaryRecordingID == nil {
                    updateOverlay(title: "正在聆听", transcript: partialTranscript, recording: true, visible: true)
                }
            }
        case let .partial(text):
            do {
                try sessionState.apply(.partial)
            } catch {
                await fail(
                    error.localizedDescription,
                    event: "protocol_event_out_of_order",
                    generation: generation
                )
                return
            }
            if firstPartialAt == nil {
                firstPartialAt = clock.now
                if let sessionStartedAt {
                    diagnostics.record("asr_first_partial", fields: [
                        "latency_ms": Self.milliseconds(sessionStartedAt.duration(to: clock.now))
                    ])
                }
            }
            partialTranscript = text
            if dictionaryRecordingID == nil {
                if state == .finalizing {
                    updateOverlay(title: finalizingTitle, transcript: text, recording: false, visible: true)
                } else {
                    updateOverlay(title: "正在聆听", transcript: text, recording: true, visible: true)
                }
            }
        case let .final(text):
            eventTask = nil
            finalTimeoutTask?.cancel()
            do {
                try sessionState.apply(.final)
            } catch {
                await fail(
                    error.localizedDescription,
                    event: "protocol_event_out_of_order",
                    generation: generation
                )
                return
            }
            if let stopRequestedAt {
                diagnostics.record("asr_final", fields: [
                    "latency_ms": Self.milliseconds(stopRequestedAt.duration(to: clock.now))
                ])
            }
            if let dictionaryID = dictionaryRecordingID {
                guard let spoken = DictionaryPronunciation.spokenForm(from: text) else {
                    await fail("没有识别到有效读音，请重试", event: "dictionary_pronunciation_invalid", generation: generation)
                    return
                }
                guard let index = settingsStore.settings.dictionary.firstIndex(where: { $0.id == dictionaryID }) else {
                    await fail("词条已被删除，识别结果没有保存", event: "dictionary_entry_removed", generation: generation)
                    return
                }
                settingsStore.settings.dictionary[index].spoken = spoken
                await cleanUpSession(expectedGeneration: generation)
                try? sessionState.apply(.inserted)
                state = .idle
                partialTranscript = ""
                dictionaryRecordingMessage = "读音已填入，请自行填写写法"
                return
            }
            let processed = TextPostProcessor.normalized(
                TextPostProcessor.applyDictionary(settingsStore.settings.dictionary, to: text)
            )
            guard !processed.isEmpty else {
                await fail(
                    "没有识别到可插入的文字",
                    event: "empty_transcript",
                    generation: generation
                )
                return
            }
            state = .inserting
            updateOverlay(title: "正在插入", transcript: processed, recording: false, visible: true)
            guard let insertionTarget = activeTextInsertionTarget else {
                await fail(
                    "原输入位置已经失效",
                    event: "text_insertion_target_lost",
                    generation: generation
                )
                return
            }
            do {
                try await textInsertion.insert(processed, into: insertionTarget)
            } catch {
                guard activeSessionGeneration == generation else { return }
                partialTranscript = processed
                recoverableTranscript = processed
                await fail(
                    "\(error.localizedDescription)。识别文字已临时保留，可从菜单栏复制",
                    event: "text_insertion_failed",
                    generation: generation
                )
                return
            }
            guard activeSessionGeneration == generation else { return }
            let elapsed = sessionStartedAt.map { $0.duration(to: clock.now) }
            await cleanUpSession(expectedGeneration: generation)
            do {
                try sessionState.apply(.inserted)
            } catch {
                try? sessionState.apply(.fail)
                state = .error("文字已插入，但会话状态未能正常复位")
                updateOverlay(
                    title: "已插入，状态异常",
                    transcript: "请重新使用快捷键开始下一次输入",
                    recording: false,
                    visible: true
                )
                diagnostics.record(.error, "session_transition_failed")
                return
            }
            state = .idle
            partialTranscript = ""
            recoverableTranscript = nil
            diagnostics.record("recognition_inserted", fields: [
                "duration_ms": elapsed.map(Self.milliseconds) ?? "unknown",
                "characters": String(processed.count)
            ])
            if settingsStore.settings.playSounds { NSSound(named: "Pop")?.play() }
            try? await Task.sleep(for: .milliseconds(650))
            if state == .idle { overlayController.hide() }
        case let .error(code, message):
            eventTask = nil
            await fail(
                message,
                event: "asr_error",
                fields: ["code": code],
                generation: generation
            )
        }
    }

    private func startFinalTimeout(generation: UUID) {
        finalTimeoutTask?.cancel()
        let timeoutSeconds = activeInputMode == .faithful ? 12 : 35
        finalTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            guard !Task.isCancelled,
                  let self,
                  self.activeSessionGeneration == generation,
                  self.state == .finalizing
            else { return }
            await self.fail(
                ASRProtocolError.finalTimedOut.localizedDescription,
                event: "final_timeout",
                generation: generation
            )
        }
    }

    private func startReadyTimeout(generation: UUID) {
        readyTimeoutTask?.cancel()
        readyTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled,
                  let self,
                  self.activeSessionGeneration == generation,
                  self.state == .connecting || self.state == .finalizing
            else { return }
            guard self.sessionState.phase == .connecting
                || self.sessionState.phase == .finalizingAwaitingReady
            else { return }
            await self.fail(
                "识别服务未在 8 秒内就绪",
                event: "ready_timeout",
                generation: generation
            )
        }
    }

    private func startMaximumSessionTimeout(generation: UUID) {
        maximumSessionTask?.cancel()
        maximumSessionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled,
                  let self,
                  self.activeSessionGeneration == generation
            else { return }
            guard self.state == .connecting || self.state == .listening else { return }
            self.diagnostics.record(.warning, "maximum_session_reached")
            await self.endInput()
        }
    }

    private func fail(
        _ message: String,
        event: String,
        fields: [String: String] = [:],
        generation: UUID? = nil
    ) async {
        if let generation, activeSessionGeneration != generation { return }
        let wasDictionaryRecording = dictionaryRecordingID != nil
        await cleanUpSession(expectedGeneration: generation)
        try? sessionState.apply(.fail)
        state = .error(message)
        if wasDictionaryRecording {
            dictionaryRecordingMessage = message
        } else {
            updateOverlay(title: "无法完成 · 按 Esc 隐藏", transcript: message, recording: false, visible: true)
        }
        diagnostics.record(.error, event, fields: fields)
    }

    private func cleanUpSession(expectedGeneration: UUID? = nil) async {
        if let expectedGeneration, activeSessionGeneration != expectedGeneration { return }
        activeSessionGeneration = nil
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
        maximumSessionTask?.cancel()
        maximumSessionTask = nil
        finalTimeoutTask?.cancel()
        finalTimeoutTask = nil
        audioCapture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        audioSendTask?.cancel()
        audioSendTask = nil
        eventTask?.cancel()
        eventTask = nil
        await asrClient.cancel()
        overlayState.level = 0
        activeTextInsertionTarget = nil
        activeInputMode = nil
        dictionaryRecordingID = nil
    }

    private func prepareForTermination() {
        microphoneTest.cancel()
        dictionarySyncLoop?.cancel()
        activeSessionGeneration = nil
        readyTimeoutTask?.cancel()
        maximumSessionTask?.cancel()
        finalTimeoutTask?.cancel()
        audioSendTask?.cancel()
        eventTask?.cancel()
        audioCapture.stop()
        audioContinuation?.finish()
        hotKeyMonitor.stop()
        hotKeyIsPressed = false
        activePressMode = nil
        hotKeyBeginRequestID = nil
        recoverableTranscript = nil
        activeTextInsertionTarget = nil
        dictionaryRecordingID = nil
        settingsStore.flush()
    }

    private func updateOverlay(title: String, transcript: String, recording: Bool, visible: Bool) {
        overlayState.title = title
        overlayState.transcript = transcript
        overlayState.isRecording = recording
        guard settingsStore.settings.showOverlay else { return }
        if visible { overlayController.show() } else { overlayController.hide() }
    }

    private var finalizingTitle: String {
        activeInputMode == .faithful ? "正在完成识别" : "AI 正在整理"
    }

    private func firstEvent(
        from stream: AsyncStream<ASREvent>,
        timeout: Duration
    ) async -> ASREvent? {
        await withTaskGroup(of: ASREvent?.self) { group in
            group.addTask {
                for await event in stream { return event }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let value = await group.next() ?? nil
            group.cancelAll()
            return value
        }
    }

    private static func milliseconds(_ duration: Duration) -> String {
        let components = duration.components
        let milliseconds = components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
        return String(milliseconds)
    }
}
