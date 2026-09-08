import CryptoKit
import Foundation
import Security

/// A key handed back by `HistoryKeyProviding`, plus whether this call is the one that generated
/// and stored it — the signal `DictationStore.init` uses to tell "first run" from "the key vanished".
public struct HistoryKey: Sendable {
    public let key: SymmetricKey
    public let isNewlyCreated: Bool
    public init(key: SymmetricKey, isNewlyCreated: Bool) {
        self.key = key
        self.isNewlyCreated = isNewlyCreated
    }
}

/// Hands out the symmetric key that encrypts history rows (design ST-05 "Key stored in the Secure Enclave").
public protocol HistoryKeyProviding: Sendable {
    func historyKey() throws -> HistoryKey
}

public enum HistoryKeyProviders {
    public enum Choice: Equatable { case secureEnclave, keychain }

    public static func select(secureEnclaveAvailable: Bool) -> Choice { secureEnclaveAvailable ? .secureEnclave : .keychain }

    /// Secure Enclave when the hardware and signature allow it (not on CI VMs), else a Keychain-held random key.
    public static func `default`(service: String = "dev.artemsem.voxflow", account: String = "history-key") -> any HistoryKeyProviding {
        switch select(secureEnclaveAvailable: SecureEnclave.isAvailable) {
        case .secureEnclave: SecureEnclaveKeyProvider(service: service, account: account)
        case .keychain: KeychainKeyProvider(service: service, account: account)
        }
    }
}

/// A random 256-bit key stored as a generic password (`ThisDeviceOnly`, after first unlock).
public struct KeychainKeyProvider: HistoryKeyProviding {
    let service: String, account: String
    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    public func historyKey() throws -> HistoryKey {
        if let data = try KeychainItem.read(service: service, account: account) {
            return HistoryKey(key: SymmetricKey(data: data), isNewlyCreated: false)
        }
        let generated = SymmetricKey(size: .bits256)
        let generatedData = generated.withUnsafeBytes { Data($0) }
        // `writeOrRead` can lose a race to another caller and hand back someone else's already-stored
        // bytes instead of ours (`errSecDuplicateItem`) — only a byte-for-byte match means *this* call
        // is the one that actually created the key.
        let stored = try KeychainItem.writeOrRead(generatedData, service: service, account: account)
        return HistoryKey(key: SymmetricKey(data: stored), isNewlyCreated: stored == generatedData)
    }

    func deleteForTesting() throws { try KeychainItem.delete(service: service, account: account) }
}

/// The two halves an SE-derived key needs to be reconstructed, kept as one JSON blob behind one
/// Keychain item so they can never be observed (or written) half-present.
struct SecureEnclaveKeyPair: Codable, Equatable {
    let se: Data
    let salt: Data
}

/// ECIES-style wrap: a P-256 key agreement key that never leaves the Secure Enclave, combined with a stored
/// public "salt" key, derives the AES key through HKDF. Both halves persist as one Keychain item (a JSON blob
/// of `SecureEnclaveKeyPair`) so a crash, restore, or race between writing them can never leave one half
/// present without the other — the SE key is only a handle (`dataRepresentation`), so the AES key cannot be
/// reconstructed on another machine.
public struct SecureEnclaveKeyProvider: HistoryKeyProviding {
    let service: String, account: String
    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    public func historyKey() throws -> HistoryKey {
        guard SecureEnclave.isAvailable else { throw StorageError.secureEnclaveUnavailable }
        let pair: SecureEnclaveKeyPair
        var isNewlyCreated = false
        if let blob = try KeychainItem.read(service: service, account: account + ".se") {
            pair = try JSONDecoder().decode(SecureEnclaveKeyPair.self, from: blob)
        } else {
            // Generate both halves before the single write, so the write can never observe
            // (or produce) a state where only one half exists.
            let newPrivateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey()
            let newSaltPublic = P256.KeyAgreement.PrivateKey().publicKey      // private half discarded on purpose
            let generated = SecureEnclaveKeyPair(se: newPrivateKey.dataRepresentation, salt: newSaltPublic.rawRepresentation)
            let generatedData = try JSONEncoder().encode(generated)
            // As with the Keychain provider: only a byte-for-byte match on the stored blob means this
            // call actually won the write (vs. losing an `errSecDuplicateItem` race and reading back
            // another caller's pair).
            let stored = try KeychainItem.writeOrRead(generatedData, service: service, account: account + ".se")
            isNewlyCreated = stored == generatedData
            pair = try JSONDecoder().decode(SecureEnclaveKeyPair.self, from: stored)
        }
        let privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: pair.se)
        let saltPublic = try P256.KeyAgreement.PublicKey(rawRepresentation: pair.salt)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: saltPublic)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("VoxFlow history".utf8), sharedInfo: Data(), outputByteCount: 32)
        return HistoryKey(key: key, isNewlyCreated: isNewlyCreated)
    }
}

enum KeychainItem {
    static func read(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StorageError.keychain(status) }
        return item as? Data
    }

    /// Writes `data` as a new item and returns it; if another caller already wrote first
    /// (`errSecDuplicateItem`, e.g. two providers racing on first run), re-reads and returns the
    /// existing item instead of failing — the loser of the race converges on the winner's value.
    @discardableResult
    static func writeOrRead(_ data: Data, service: String, account: String) throws -> Data {
        let attributes: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                         kSecAttrAccount as String: account, kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            if let existing = try read(service: service, account: account) { return existing }
            throw StorageError.keychain(status)
        }
        guard status == errSecSuccess else { throw StorageError.keychain(status) }
        return data
    }

    static func delete(service: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StorageError.keychain(status) }
    }
}
