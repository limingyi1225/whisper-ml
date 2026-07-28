import Foundation
import Security

/// Credentials live in the login keychain, not in the binary or in UserDefaults.
enum KeychainStore {
    private static let service = "com.mingyili.Whisper"
    private static let apiKeyAccount = "openai-api-key"
    private static let relayTokenAccount = "relay-device-token"

    static func loadAPIKey() -> String? {
        load(account: apiKeyAccount)
    }

    static func loadRelayToken() -> String? {
        load(account: relayTokenAccount)
    }

    /// Whether a credential is stored, without copying it out.
    ///
    /// The settings pane asks this on every render — which for a pane containing a
    /// `SecureField` means once per keystroke. Answering with `load(…) != nil` decrypted
    /// the item and materialised the plaintext secret each time, purely to compare it
    /// against nil. `kSecReturnData: false` answers the same question from the item's
    /// attributes.
    static func hasAPIKey() -> Bool { exists(account: apiKeyAccount) }

    static func hasRelayToken() -> Bool { exists(account: relayTokenAccount) }

    private static func exists(account: String) -> Bool {
        var query: [String: Any] = baseQuery(account: account)
        query[kSecReturnData as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private static func load(account: String) -> String? {
        var query: [String: Any] = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    /// Returns `true` only when a key was actually written. Whitespace-only input
    /// is rejected rather than treated as a delete — callers report `true` as
    /// "已存入钥匙串", and silently *removing* the key under that message would
    /// leave the user believing the opposite of what happened.
    @discardableResult
    static func saveAPIKey(_ key: String) -> Bool {
        save(key, account: apiKeyAccount)
    }

    @discardableResult
    static func saveRelayToken(_ token: String) -> Bool {
        save(token, account: relayTokenAccount)
    }

    private static func save(_ value: String, account: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let data = Data(trimmed.utf8)
        // Try update first; fall back to insert when there is nothing to update.
        let updateStatus = SecItemUpdate(
            baseQuery(account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }

        var insert = baseQuery(account: account)
        insert[kSecValueData as String] = data
        // No kSecAttrAccessible here: it is only honored for data-protection
        // keychain items, and this is a file-based login-keychain item — setting
        // it would document a guarantee that is silently not enforced.
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func deleteAPIKey() -> Bool {
        delete(account: apiKeyAccount)
    }

    @discardableResult
    static func deleteRelayToken() -> Bool {
        delete(account: relayTokenAccount)
    }

    private static func delete(account: String) -> Bool {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
