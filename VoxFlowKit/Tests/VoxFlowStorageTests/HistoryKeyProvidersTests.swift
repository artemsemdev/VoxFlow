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

    @Test("Keychain provider returns a stable key across calls (RequiresKeychain)",
          .enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_KEYCHAIN_TESTS"] == "1"))
    func keychain() throws {
        let provider = KeychainKeyProvider(service: "dev.artemsem.voxflow.tests", account: UUID().uuidString)
        defer { try? provider.deleteForTesting() }
        let a = try provider.historyKey(), b = try provider.historyKey()
        #expect(a == b)
    }
}
