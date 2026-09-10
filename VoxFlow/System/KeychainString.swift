import Foundation
import os
import Security

/// A minimal generic-password Keychain reader/writer for app-level string secrets.
/// `VoxFlowStorage.KeychainItem` already does this for the history encryption key, but it's
/// `internal` to that package — this is the app's own small copy of the same SecItem calls,
/// currently only used for the MCP access token (design ST-06, `dev.artemsem.voxflow` /
/// `mcp-token`).
enum KeychainString {
    private static let log = Logger(subsystem: "dev.artemsem.voxflow", category: "keychain")

    static func read(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainStringError.status(status) }
        return String(data: data, encoding: .utf8)
    }

    /// Updates the item in place if one already exists (so the token's Keychain entry keeps a
    /// stable identity across regenerations), otherwise adds it fresh.
    static func write(_ value: String, service: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                // M2: `SecItemUpdate` just reported `errSecItemNotFound` for this exact query, yet
                // `SecItemAdd` says the item already exists — the item is present but unreadable/
                // unwritable under the current signing identity (e.g. a changing ad-hoc dev
                // identity). Logged specifically (not just the generic throw below) so this is
                // visible in Console instead of silently regenerating an in-memory-only token on
                // every launch with no signal.
                Self.log.error("Keychain item exists but is unreadable under the current signing identity (service: \(service, privacy: .public), account: \(account, privacy: .public)) — value will not persist across relaunch")
            }
            guard addStatus == errSecSuccess else { throw KeychainStringError.status(addStatus) }
            return
        }
        guard updateStatus == errSecSuccess else { throw KeychainStringError.status(updateStatus) }
    }
}

enum KeychainStringError: Error, Equatable {
    case status(OSStatus)
}
