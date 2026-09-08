import CryptoKit
import Foundation

/// AES-GCM per value; the combined box (nonce + ciphertext + tag) is what lands in SQLite.
public struct DictationCipher: Sendable {
    private let key: SymmetricKey
    public init(key: SymmetricKey) { self.key = key }

    public func seal(_ text: String) throws -> Data {
        try AES.GCM.seal(Data(text.utf8), using: key).combined!
    }

    public func open(_ data: Data) throws -> String {
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
        guard let text = String(data: plain, encoding: .utf8) else { throw StorageError.corruptRow }
        return text
    }
}

public enum StorageError: Error, Equatable, Sendable {
    case corruptRow
    case keychain(OSStatus)
    case secureEnclaveUnavailable
}
