import Foundation
import Security

/// The Map Lock session token. The worker stores only a hash of this value.
/// Every Security call stays off the main thread. SecItemCopyMatching can block for seconds.
enum KeychainStore {
    private static let service = "com.elliot.maplock.session"
    private static let account = "session"
    private static let queue = DispatchQueue(label: "com.elliot.maplock.keychain", qos: .userInitiated)

    static func saveSession(_ token: String) {
        queue.async { saveSync(token) }
    }

    static func loadSession() async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: loadSync())
            }
        }
    }

    static func deleteSession() {
        queue.async { deleteSync() }
    }

    private static func saveSync(_ token: String) {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func loadSync() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else { return nil }
        return token
    }

    private static func deleteSync() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
