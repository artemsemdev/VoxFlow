import CryptoKit
import Foundation
import Testing
@testable import VoxFlowStorage

@Suite("DictationCipher")
struct DictationCipherTests {
    @Test("seal/open round-trips unicode; different nonces per call; wrong key fails")
    func roundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let cipher = DictationCipher(key: key)
        let a = try cipher.seal("Привет, VoxFlow 👋")
        let b = try cipher.seal("Привет, VoxFlow 👋")
        #expect(a != b)
        #expect(try cipher.open(a) == "Привет, VoxFlow 👋")
        #expect(throws: (any Error).self) { try DictationCipher(key: SymmetricKey(size: .bits256)).open(a) }
    }
}
