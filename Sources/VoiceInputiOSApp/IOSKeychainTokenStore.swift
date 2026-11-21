import Foundation
import Security

enum IOSKeychainTokenError: LocalizedError {
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
            return "钥匙串中的 Token 格式无效"
        }
    }
}

struct IOSKeychainTokenStore {
    private let service = "com.aivoiceinput.ios"
    private let account = "asr-bearer-token"

    func load() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess else {
            throw IOSKeychainTokenError.unexpectedStatus(status)
        }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw IOSKeychainTokenError.invalidData
        }
        return token
    }

    func save(_ token: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw IOSKeychainTokenError.unexpectedStatus(status)
            }
            return
        }

        let data = Data(normalized.utf8)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw IOSKeychainTokenError.unexpectedStatus(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw IOSKeychainTokenError.unexpectedStatus(addStatus)
        }
    }
}
