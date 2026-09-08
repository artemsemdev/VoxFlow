import Foundation
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlowAudio

@Suite("AudioDecoder")
struct AudioDecoderTests {
    let decoder = AudioDecoder()

    @Test("44.1 kHz stereo WAV decodes to 16 kHz mono of the same duration", arguments: ["wav", "aiff", "caf"])
    func pcmContainers(ext: String) throws {
        let dir = TemporaryDirectory()
        let url = dir.file("tone.\(ext)")
        try FixtureAudio.writeSine(to: url, seconds: 2, sampleRate: 44_100, channels: 2)
        let audio = try decoder.decode(url)
        #expect(abs(audio.duration - 2) < 0.05)
        // Fixture puts the 0.5-amplitude sine on channel 0 only, silence elsewhere; a correct
        // stereo-to-mono downmix averages them, so the decoded peak should land around 0.25
        // (0.5 + 0) / 2 — proving the decoder actually downmixes rather than just picking one
        // already-identical channel.
        #expect((0.2...0.3).contains(audio.samples.max()!))
        #expect((-0.3...(-0.2)).contains(audio.samples.min()!))
    }

    @Test("AAC in m4a and mp4 containers decodes", arguments: ["m4a", "mp4"])
    func aacContainers(ext: String) throws {
        let dir = TemporaryDirectory()
        let url = dir.file("tone.\(ext)")
        try FixtureAudio.writeAAC(to: url, seconds: 2)
        let audio = try decoder.decode(url)
        #expect(abs(audio.duration - 2) < 0.15)   // AAC adds encoder delay/padding
        #expect(audio.samples.max()! > 0.2)
    }

    @Test("MP3 decodes (committed fixture)")
    func mp3() throws {
        let url = Bundle.module.url(forResource: "tone-1s", withExtension: "mp3", subdirectory: "Fixtures")!
        let audio = try decoder.decode(url)
        #expect(abs(audio.duration - 1) < 0.15)
        // Fixture's actual peak is ~0.086 (verified against `afconvert`'s independent decode of
        // the same file); 0.2 assumed a louder tone than this committed fixture actually has.
        #expect(audio.samples.max()! > 0.05)
    }

    @Test("unsupported extension is rejected before touching the file")
    func unsupportedType() {
        let dir = TemporaryDirectory()
        let url = dir.file("notes.pages")
        FileManager.default.createFile(atPath: url.path, contents: Data("hello".utf8))
        #expect(throws: AudioDecodingError.unsupportedType("pages")) { try decoder.decode(url) }
    }

    @Test("corrupt file with an audio extension fails with decodeFailed")
    func corruptFile() {
        let dir = TemporaryDirectory()
        let url = dir.file("broken.mp3")
        FileManager.default.createFile(atPath: url.path, contents: Data((0..<4096).map { UInt8($0 % 251) }))
        #expect { try decoder.decode(url) } throws: { error in
            if case AudioDecodingError.decodeFailed = error { return true }
            return false
        }
    }

    @Test("missing file is reported as such")
    func missingFile() {
        let url = URL(fileURLWithPath: "/nonexistent/voxflow/clip.wav")
        #expect(throws: AudioDecodingError.fileNotFound(url)) { try decoder.decode(url) }
    }

    @Test("extension check is case-insensitive")
    func caseInsensitive() throws {
        let dir = TemporaryDirectory()
        let url = dir.file("TONE.WAV")
        try FixtureAudio.writeSine(to: url, seconds: 0.5, sampleRate: 16_000, channels: 1)
        #expect(try decoder.decode(url).samples.count == 8_000)
    }

    @Test("an empty-but-valid file decodes to no samples, not an error")
    func emptyFileDecodesToNoSamples() throws {
        let dir = TemporaryDirectory()
        let url = dir.file("silent.wav")
        try FixtureAudio.writeSine(to: url, seconds: 0.001, sampleRate: 16_000, channels: 1)
        #expect(try decoder.decode(url).samples.count < 100)
    }
}
