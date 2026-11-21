import CryptoKit
import Foundation

enum SecureSettingsError: LocalizedError, Equatable {
    case encryptionKeyMissing
    case invalidEncryptionKey
    case invalidEncryptedFile

    var errorDescription: String? {
        switch self {
        case .encryptionKeyMissing:
            "设置加密密钥不在钥匙串中"
        case .invalidEncryptionKey:
            "设置加密密钥格式无效"
        case .invalidEncryptedFile:
            "加密设置文件格式无效或已损坏"
        }
    }
}

struct SecureSettingsCodec {
    private static let magic = Data("VOICEINPUT-SETTINGS-V1\n".utf8)
    private let loadKeyData: () throws -> Data?
    private let saveKeyData: (Data?) throws -> Void

    init() {
        let keyStore = KeychainDataStore(account: "settings-encryption-key-v1")
        loadKeyData = keyStore.load
        saveKeyData = keyStore.save
    }

    init(
        loadKeyData: @escaping () throws -> Data?,
        saveKeyData: @escaping (Data?) throws -> Void
    ) {
        self.loadKeyData = loadKeyData
        self.saveKeyData = saveKeyData
    }

    func encrypt(_ plaintext: Data) throws -> Data {
        let key = try loadOrCreateKey()
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            throw SecureSettingsError.invalidEncryptedFile
        }
        return Self.magic + combined
    }

    func decrypt(_ encrypted: Data) throws -> Data {
        guard encrypted.starts(with: Self.magic) else {
            throw SecureSettingsError.invalidEncryptedFile
        }
        guard let keyData = try loadKeyData() else {
            throw SecureSettingsError.encryptionKeyMissing
        }
        let key = try key(from: keyData)
        do {
            let sealed = try AES.GCM.SealedBox(combined: encrypted.dropFirst(Self.magic.count))
            return try AES.GCM.open(sealed, using: key)
        } catch {
            throw SecureSettingsError.invalidEncryptedFile
        }
    }

    func resetKey() throws {
        try saveKeyData(nil)
    }

    private func loadOrCreateKey() throws -> SymmetricKey {
        if let data = try loadKeyData() {
            return try key(from: data)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try saveKeyData(data)
        return key
    }

    private func key(from data: Data) throws -> SymmetricKey {
        guard data.count == 32 else { throw SecureSettingsError.invalidEncryptionKey }
        return SymmetricKey(data: data)
    }
}
