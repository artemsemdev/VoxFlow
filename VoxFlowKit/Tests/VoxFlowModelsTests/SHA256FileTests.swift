import Foundation
import Testing
import VoxFlowTestSupport
@testable import VoxFlowModels

@Suite("SHA256File")
struct SHA256FileTests {
    @Test("hashes a file streamed in chunks")
    func hashes() throws {
        let dir = TemporaryDirectory()
        let url = dir.file("abc.txt")
        try Data("abc".utf8).write(to: url)
        #expect(try SHA256File.hexDigest(of: url) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
