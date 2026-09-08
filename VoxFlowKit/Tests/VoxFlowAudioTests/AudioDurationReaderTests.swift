import Foundation
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlowAudio

@Suite("AudioDurationReader")
struct AudioDurationReaderTests {
    @Test("reads the duration without decoding")
    func duration() async throws {
        let dir = TemporaryDirectory()
        let url = dir.file("tone.wav")
        try FixtureAudio.writeSine(to: url, seconds: 3, sampleRate: 44_100, channels: 1)
        let seconds = try await AudioDurationReader().duration(of: url)
        #expect(abs(seconds - 3) < 0.05)
    }

    @Test("unsupported or unreadable files throw AudioDecodingError")
    func unreadable() async {
        let dir = TemporaryDirectory()
        let url = dir.file("notes.pages")
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        await #expect(throws: AudioDecodingError.unsupportedType("pages")) { _ = try await AudioDurationReader().duration(of: url) }
    }
}
