import Foundation
import Testing
import VoxFlowCore
import VoxFlowFiles
import VoxFlowTestSupport
@testable import VoxFlow

/// Proves export happens at the app level, independent of any Files view model (MB-04 background
/// completion) — this is what makes the Dock-open path (queue running while Files isn't shown)
/// still land a transcript in `~/Transcripts/…`.
@Suite("ExportCoordinator") @MainActor
struct ExportCoordinatorTests {
    static let a = URL(fileURLWithPath: "/tmp/interview-raw.m4a")

    static func doc(_ url: URL) -> TranscriptDocument {
        TranscriptDocument(sourceURL: url, transcript: Transcript(segments: [TranscriptSegment(start: 0, end: 1, text: "ok")!], language: "en"),
                           modelID: "m", audioDuration: 60, processingTime: 1, createdAt: Date(timeIntervalSince1970: 0))
    }

    @MainActor
    struct Harness {
        let dir = TemporaryDirectory()
        let transcriber = FakeFileTranscriber()
        let durations = FakeAudioDuration([a: 60])
        let settings = FilesSettings(store: InMemoryKeyValueStore())
        let queue: FileQueue
        let exports: ExportCoordinator

        init(exportDirectory: URL? = nil) {
            queue = FileQueue(transcriber: transcriber, durations: durations, supportedExtensions: SupportedAudio.extensions,
                              options: { TranscriptionOptions() })
            let exportDir = exportDirectory ?? dir.file("Transcripts")
            exports = ExportCoordinator(queue: queue, settings: settings, exporter: { TranscriptExporter(directory: exportDir) })
        }

        func settle() async {
            await queue.waitUntilIdle()
            for _ in 0..<50 { await Task.yield() }
        }
    }

    @Test("a finished job is exported in the configured format — no Files view model involved")
    func exportsOnFinished() async throws {
        let h = Harness()
        await h.transcriber.script(Self.a, .document(Self.doc(Self.a)))
        await h.queue.add([Self.a])
        await h.queue.start()
        await h.settle()

        let item = try #require(await h.queue.items.first)
        let url = try #require(h.exports.url(for: item.id))
        #expect(url.lastPathComponent == "interview-raw.txt")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("removing a row clears its recorded export URL and error")
    func clearsOnRemoved() async throws {
        let h = Harness()
        await h.transcriber.script(Self.a, .document(Self.doc(Self.a)))
        await h.queue.add([Self.a])
        await h.queue.start()
        await h.settle()

        let item = try #require(await h.queue.items.first)
        #expect(h.exports.url(for: item.id) != nil)

        await h.queue.remove(id: item.id)
        for _ in 0..<50 { await Task.yield() }
        #expect(h.exports.url(for: item.id) == nil)
        #expect(h.exports.error(for: item.id) == nil)
    }

    @Test("an unwritable export folder records an error instead of crashing")
    func recordsErrorForUnwritableFolder() async throws {
        let outerDir = TemporaryDirectory()
        let blockedPath = outerDir.file("Transcripts")
        try Data("not a directory".utf8).write(to: blockedPath)   // a plain file where the exporter needs a directory
        let h = Harness(exportDirectory: blockedPath)
        await h.transcriber.script(Self.a, .document(Self.doc(Self.a)))
        await h.queue.add([Self.a])
        await h.queue.start()
        await h.settle()

        let item = try #require(await h.queue.items.first)
        #expect(h.exports.url(for: item.id) == nil)
        #expect(h.exports.error(for: item.id) != nil)
    }

    // MARK: onExported (review I2 — MB-04 posts from this, not from FileQueue.finished)

    @Test("onExported fires once, with the item, document, real written URL and format actually used, on success")
    func onExportedFiresOnSuccess() async throws {
        let h = Harness()
        await h.transcriber.script(Self.a, .document(Self.doc(Self.a)))
        var calls: [(QueueItem, TranscriptDocument, URL, OutputFormat)] = []
        h.exports.onExported = { calls.append(($0, $1, $2, $3)) }

        await h.queue.add([Self.a])
        await h.queue.start()
        await h.settle()

        let item = try #require(await h.queue.items.first)
        let url = try #require(h.exports.url(for: item.id))
        #expect(calls.count == 1)
        #expect(calls.first?.0.id == item.id)
        #expect(calls.first?.2 == url)
        #expect(calls.first?.3 == h.settings.outputFormat)
    }

    @Test("onExported never fires when the export itself fails, even though the transcription succeeded")
    func onExportedNeverFiresOnFailure() async throws {
        let outerDir = TemporaryDirectory()
        let blockedPath = outerDir.file("Transcripts")
        try Data("not a directory".utf8).write(to: blockedPath)
        let h = Harness(exportDirectory: blockedPath)
        await h.transcriber.script(Self.a, .document(Self.doc(Self.a)))
        var calls = 0
        h.exports.onExported = { _, _, _, _ in calls += 1 }

        await h.queue.add([Self.a])
        await h.queue.start()
        await h.settle()

        #expect(h.exports.error(for: (try #require(await h.queue.items.first)).id) != nil)
        #expect(calls == 0)
    }
}
