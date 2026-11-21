import Foundation
import Security

enum KeychainTokenError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "钥匙串操作失败：\(message)"
            }
            return "钥匙串操作失败（\(status)）"
        case .invalidData:
            return "钥匙串中的数据格式无效"
        }
    }
}

struct KeychainDataStore {
    private let service = "com.aivoiceinput.mac"
    let account: String

    func load() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainTokenError.unexpectedStatus(status) }
        guard let data = result as? Data else { throw KeychainTokenError.invalidData }
        return data
    }

    func save(_ data: Data?) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        guard let data, !data.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainTokenError.unexpectedStatus(status)
            }
            return
        }

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainTokenError.unexpectedStatus(updateStatus)
        }
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainTokenError.unexpectedStatus(addStatus) }
    }
}

struct KeychainTokenStore {
    private let store = KeychainDataStore(account: "asr-bearer-token")

    func load() throws -> String {
        guard let data = try store.load() else { return "" }
        guard let token = String(data: data, encoding: .utf8) else {
            throw KeychainTokenError.invalidData
        }
        return token
    }

    func save(_ token: String) throws {
        let data = token.isEmpty ? nil : Data(token.utf8)
        try store.save(data)
    }
}
