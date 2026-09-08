import Foundation
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlowFiles

@Suite("TranscriptExporter")
struct TranscriptExporterTests {
    let document = TranscriptRendererTests.document

    @Test("writes <base>.<ext> and avoids overwriting with -2, -3")
    func collisionSafe() throws {
        let dir = TemporaryDirectory()
        let exporter = TranscriptExporter(directory: dir.url)
        let first = try exporter.export(document, format: .srt, timestamps: true)
        let second = try exporter.export(document, format: .srt, timestamps: true)
        let third = try exporter.export(document, format: .srt, timestamps: true)
        #expect(first.lastPathComponent == "lecture-04.srt")
        #expect(second.lastPathComponent == "lecture-04-2.srt")
        #expect(third.lastPathComponent == "lecture-04-3.srt")
        #expect(try String(contentsOf: first, encoding: .utf8) == TranscriptRenderer.render(document, format: .srt, timestamps: true))
    }

    @Test("creates the directory and exports several formats at once")
    func exportAll() throws {
        let dir = TemporaryDirectory()
        let nested = dir.file("Transcripts")
        let urls = try TranscriptExporter(directory: nested).exportAll(document, formats: [.txt, .json], timestamps: false)
        #expect(Set(urls.keys) == [.txt, .json])
        #expect(FileManager.default.fileExists(atPath: nested.appendingPathComponent("lecture-04.json").path))
    }

    @Test("default directory is ~/Transcripts")
    func defaultDirectory() {
        #expect(TranscriptExporter.defaultDirectory.lastPathComponent == "Transcripts")
        #expect(TranscriptExporter.defaultDirectory.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path))
    }
}
