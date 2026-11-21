import Foundation
import ServiceManagement
import VoiceInputCore

struct SettingsDocument: Codable {
    let schemaVersion: Int
    var settings: AppSettings
    var dictionarySyncBaseline: DictionarySyncSnapshot? = nil
    var microphoneDeviceUID: String? = nil
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet { scheduleSave() }
    }
    @Published var token: String {
        didSet { scheduleTokenSave() }
    }
    @Published var microphoneDeviceUID: String? = nil {
        didSet { scheduleSave() }
    }
    @Published private(set) var persistenceError: String?
    @Published private(set) var requiresSettingsReset = false
    @Published private(set) var dictionarySyncBaseline: DictionarySyncSnapshot?

    private let fileURL: URL
    private let legacyFileURL: URL
    private let keychain = KeychainTokenStore()
    private let secureCodec = SecureSettingsCodec()
    private var saveTask: Task<Void, Never>?
    private var tokenSaveTask: Task<Void, Never>?
    private var isLoading = true
    private var settingsWriteBlocked = false
    private var settingsPersistenceError: String?
    private var tokenPersistenceError: String?
    private var launchAtLoginError: String?

    var authorizationToken: String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init() {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceInput", isDirectory: true)
        fileURL = baseURL.appendingPathComponent("settings.enc")
        legacyFileURL = baseURL.appendingPathComponent("settings.json")
        settings = .init()
        token = ""
        load()
        isLoading = false
    }

    func flush() {
        saveTask?.cancel()
        tokenSaveTask?.cancel()
        persist()
        saveToken()
    }

    func applyLaunchAtLogin() {
        do {
            if settings.launchAtLogin {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "无法更新登录启动设置：\(error.localizedDescription)"
        }
        refreshPersistenceError()
    }

    func resetUnreadableSettings() {
        guard requiresSettingsReset else { return }
        saveTask?.cancel()
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            if FileManager.default.fileExists(atPath: legacyFileURL.path) {
                try FileManager.default.removeItem(at: legacyFileURL)
            }
            try secureCodec.resetKey()
            settingsWriteBlocked = false
            requiresSettingsReset = false
            settings = .init()
            microphoneDeviceUID = nil
            try writeSettings()
            settingsPersistenceError = nil
        } catch {
            settingsWriteBlocked = true
            requiresSettingsReset = true
            settingsPersistenceError = "重置设置失败：\(error.localizedDescription)"
        }
        refreshPersistenceError()
    }

    func clearPersonalization() {
        settings.hotwords.removeAll(keepingCapacity: false)
        settings.dictionary.removeAll(keepingCapacity: false)
        settings.appProfiles.removeAll(keepingCapacity: false)
        saveTask?.cancel()
        persist()
    }

    private func load() {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let plaintext = try secureCodec.decrypt(Data(contentsOf: fileURL))
                let document = try decodeSettings(plaintext)
                settings = document.settings
                dictionarySyncBaseline = document.dictionarySyncBaseline
                microphoneDeviceUID = document.microphoneDeviceUID
            } catch {
                settingsWriteBlocked = true
                requiresSettingsReset = true
                settingsPersistenceError = "读取设置失败：\(error.localizedDescription)"
            }
            if !settingsWriteBlocked, FileManager.default.fileExists(atPath: legacyFileURL.path) {
                do {
                    try FileManager.default.removeItem(at: legacyFileURL)
                } catch {
                    settingsPersistenceError = "清理旧明文设置失败：\(error.localizedDescription)"
                }
            }
        } else if FileManager.default.fileExists(atPath: legacyFileURL.path) {
            do {
                let document = try decodeSettings(Data(contentsOf: legacyFileURL))
                settings = document.settings
                dictionarySyncBaseline = document.dictionarySyncBaseline
                microphoneDeviceUID = document.microphoneDeviceUID
            } catch {
                settingsWriteBlocked = true
                requiresSettingsReset = true
                settingsPersistenceError = "读取旧设置失败：\(error.localizedDescription)"
            }
            if !settingsWriteBlocked {
                do {
                    try writeSettings()
                } catch {
                    settingsPersistenceError = "迁移旧设置失败：\(error.localizedDescription)"
                }
            }
        }
        migrateDeployedServerIfNeeded()
        do {
            token = try keychain.load()
        } catch {
            tokenPersistenceError = "读取服务令牌失败：\(error.localizedDescription)"
        }
        refreshPersistenceError()
    }

    private func migrateDeployedServerIfNeeded() {
        guard !settingsWriteBlocked else { return }
        let migratedURL = DeployedServerMigration.migratedURL(from: settings.serverURL)
        guard migratedURL != settings.serverURL else { return }
        settings.serverURL = migratedURL
        do {
            try writeSettings()
            settingsPersistenceError = nil
        } catch {
            settingsPersistenceError = "迁移智能整理服务地址失败：\(error.localizedDescription)"
        }
    }

    private func scheduleSave() {
        guard !isLoading else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    private func persist() {
        guard !settingsWriteBlocked else { return }
        do {
            try writeSettings()
            settingsPersistenceError = nil
        } catch {
            settingsPersistenceError = "保存设置失败：\(error.localizedDescription)"
        }
        refreshPersistenceError()
    }

    private func saveToken() {
        guard !isLoading else { return }
        do {
            try keychain.save(token.trimmingCharacters(in: .whitespacesAndNewlines))
            tokenPersistenceError = nil
        } catch {
            tokenPersistenceError = error.localizedDescription
        }
        refreshPersistenceError()
    }

    private func scheduleTokenSave() {
        guard !isLoading else { return }
        tokenSaveTask?.cancel()
        tokenSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.saveToken()
        }
    }

    private func decodeSettings(_ data: Data) throws -> SettingsDocument {
        let document = try JSONDecoder().decode(SettingsDocument.self, from: data)
        guard document.schemaVersion == 1 else {
            throw SettingsPersistenceError.unsupportedSchema
        }
        return document
    }

    func completeDictionaryEntries() throws -> [String: String] {
        var result: [String: String] = [:]
        for entry in settings.dictionary {
            let spoken = entry.spoken.trimmingCharacters(in: .whitespacesAndNewlines)
            let written = entry.written.trimmingCharacters(in: .whitespacesAndNewlines)
            if spoken.isEmpty { continue }
            if written.isEmpty {
                if let previous = dictionarySyncBaseline?.entries[spoken] {
                    result[spoken] = previous
                }
                continue
            }
            guard spoken.count <= 100, written.count <= 200,
                  result[spoken] == nil, result.count < 1_000 else {
                throw DictionarySyncError.invalidLocalEntries
            }
            result[spoken] = written
        }
        return result
    }

    func applyDictionarySync(_ snapshot: DictionarySyncSnapshot, merged: [String: String]) {
        let existing = settings.dictionary.reduce(into: [String: UUID]()) { result, entry in
            if !entry.spoken.isEmpty { result[entry.spoken] = entry.id }
        }
        let incomplete = settings.dictionary.filter {
            $0.spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                $0.written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let drafts = Set(incomplete.map(\.spoken))
        settings.dictionary = merged.keys.sorted().compactMap { spoken in
            guard !drafts.contains(spoken), let written = merged[spoken] else { return nil }
            return DictionaryEntry(id: existing[spoken] ?? UUID(), spoken: spoken, written: written)
        } + incomplete
        dictionarySyncBaseline = snapshot
        persist()
    }

    private func writeSettings() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let document = SettingsDocument(
            schemaVersion: 1,
            settings: settings,
            dictionarySyncBaseline: dictionarySyncBaseline,
            microphoneDeviceUID: microphoneDeviceUID
        )
        let encrypted = try secureCodec.encrypt(encoder.encode(document))
        try encrypted.write(to: fileURL, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        if FileManager.default.fileExists(atPath: legacyFileURL.path) {
            try FileManager.default.removeItem(at: legacyFileURL)
        }
    }

    private func refreshPersistenceError() {
        persistenceError = [settingsPersistenceError, tokenPersistenceError, launchAtLoginError]
            .compactMap { $0 }
            .joined(separator: "\n")
        if persistenceError?.isEmpty == true { persistenceError = nil }
    }
}

private enum SettingsPersistenceError: LocalizedError {
    case unsupportedSchema

    var errorDescription: String? {
        "设置文件版本过新，已使用默认设置"
    }
}
