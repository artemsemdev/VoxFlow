import CryptoKit
import Foundation
import Testing
@testable import VoxFlowStorage

@Suite("HistoryKeyProviders")
struct HistoryKeyProvidersTests {
    @Test("default picks the Secure Enclave when available, else the Keychain")
    func selection() {
        #expect(HistoryKeyProviders.select(secureEnclaveAvailable: true) == .secureEnclave)
        #expect(HistoryKeyProviders.select(secureEnclaveAvailable: false) == .keychain)
    }

    @Test("Keychain provider returns a stable key across calls, newly-created only the first time (RequiresKeychain)",
          .enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_KEYCHAIN_TESTS"] == "1"))
    func keychain() throws {
        let provider = KeychainKeyProvider(service: "dev.artemsem.voxflow.tests", account: UUID().uuidString)
        defer { try? provider.deleteForTesting() }
        let a = try provider.historyKey(), b = try provider.historyKey()
        #expect(a.key == b.key)
        #expect(a.isNewlyCreated)
        #expect(!b.isNewlyCreated)
    }

    @Test("the Secure Enclave key pair round-trips through the single-blob Codable encoding")
    func secureEnclaveKeyPairRoundTrip() throws {
        let pair = SecureEnclaveKeyPair(se: Data([0x01, 0x02, 0x03, 0x04]), salt: Data([0x05, 0x06, 0x07, 0x08]))
        let encoded = try JSONEncoder().encode(pair)
        let decoded = try JSONDecoder().decode(SecureEnclaveKeyPair.self, from: encoded)
        #expect(decoded == pair)
    }

    // I7: the SE-backed path is never exercised otherwise — this needs real Secure Enclave hardware
    // and a signing identity it accepts, so it's a manual pre-release check
    // (`VOXFLOW_SE_TESTS=1 swift test --filter HistoryKeyProviders`), not part of the default suite.
    @Test("Secure Enclave provider re-derives the same key across independent instances, newly-created only the first time (RequiresSecureEnclave)",
          .enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_SE_TESTS"] == "1"))
    func secureEnclave() throws {
        let service = "dev.artemsem.voxflow.tests"
        let account = UUID().uuidString
        let first = SecureEnclaveKeyProvider(service: service, account: account)
        defer { try? KeychainItem.delete(service: service, account: account + ".se") }
        let a = try first.historyKey()
        // A second, independent instance with the same service/account simulates a relaunch: it must
        // re-derive, not regenerate.
        let second = SecureEnclaveKeyProvider(service: service, account: account)
        let b = try second.historyKey()
        #expect(a.key == b.key)
        #expect(a.isNewlyCreated)
        #expect(!b.isNewlyCreated)
    }
}
