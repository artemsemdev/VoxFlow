import Foundation
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowFiles
import VoxFlowModels
import VoxFlowTestSupport
@testable import VoxFlow

/// Deterministic, lock-guarded clock: each call returns the current value, then advances by `step`.
/// Used to control the view model's `now:` closure so the once-per-second render throttle (design
/// 3d) can be exercised without depending on real wall-clock timing — the throttle only ever reads
/// consecutive `now()` calls, so a clock that advances by a fixed amount *per call* (not per second
/// of real time) drives it deterministically regardless of how the surrounding async work schedules.
final class TestClock: Sendable {
    private let state: Mutex<Date>
    private let step: TimeInterval

    init(start: Date = Date(timeIntervalSince1970: 0), step: TimeInterval) {
        state = Mutex(start)
        self.step = step
    }

    func now() -> Date {
        state.withLock { date in
            let current = date
            date.addTimeInterval(step)
            return current
        }
    }
}

@Suite("FilesViewModel") @MainActor
struct FilesViewModelTests {
    static let a = URL(fileURLWithPath: "/tmp/interview-raw.m4a")
    static let b = URL(fileURLWithPath: "/tmp/standup-0906.mp3")
    static let bad = URL(fileURLWithPath: "/tmp/meeting-notes.pages")

    static func doc(_ url: URL) -> TranscriptDocument {
        TranscriptDocument(sourceURL: url, transcript: Transcript(segments: [TranscriptSegment(start: 0, end: 1, text: "ok")!], language: "en"),
                           modelID: "m", audioDuration: 60, processingTime: 1, createdAt: Date(timeIntervalSince1970: 0))
    }

    @MainActor
    struct Harness {
        let dir = TemporaryDirectory()
        let transcriber = FakeFileTranscriber()
        let durations: FakeAudioDuration
        let settings = FilesSettings(store: InMemoryKeyValueStore())
        let store: ModelStore
        let queue: FileQueue
        let clock: TestClock
        let viewModel: FilesViewModel

        /// `clockStep` defaults to 2 s per `now()` call, comfortably above the 1 s render throttle
        /// so ordinary tests always see the latest progress in `items`; `etaThrottle` overrides it
        /// with a small step to exercise the throttle itself.
        init(durations: [URL: TimeInterval] = [a: 2892, b: 724], installedModel: Bool = true, clockStep: TimeInterval = 2) async throws {
            self.durations = FakeAudioDuration(durations)
            let downloader = FakeModelDownloader()
            let payload = Data(repeating: 1, count: 100)
            let model = ModelDescriptor(id: "m", displayName: "m", role: .speech, downloadURL: URL(string: "https://x/m.bin")!,
                                        sizeInBytes: 100, sha256: SHA256File.hexDigest(of: payload), languagesSummary: "", isDefault: true)
            store = ModelStore(directory: dir.file("models"), catalog: [model], downloader: downloader,
                               freeSpace: FakeFreeSpace(available: 1 << 40), settings: InMemoryKeyValueStore())
            if installedModel {
                await downloader.serve(payload, at: model.downloadURL)
                for try await _ in await store.install(id: "m") {}
            }
            queue = FileQueue(transcriber: transcriber, durations: self.durations, supportedExtensions: SupportedAudio.extensions,
                              options: { TranscriptionOptions() })
            let exportDir = dir.file("Transcripts")
            clock = TestClock(step: clockStep)
            viewModel = FilesViewModel(queue: queue, settings: settings, modelStore: store, durations: self.durations,
                                       exporter: { TranscriptExporter(directory: exportDir) }, now: clock.now)
            await viewModel.refreshModelState()
        }

        /// Lets the view model's event task apply everything the queue published so far.
        func settle() async {
            await queue.waitUntilIdle()
            for _ in 0..<50 { await Task.yield() }
        }

        /// Same drain, for a job that is deliberately held/parked (so `waitUntilIdle` would never
        /// return): waits for the transcriber to actually be parked, then lets the event pipeline
        /// (which is already fully queued behind that park) catch up.
        func drainHeld(_ url: URL) async {
            await transcriber.waitUntilHeld(url)
            for _ in 0..<50 { await Task.yield() }
        }
    }

    // MARK: 1 — long audio confirmation (3e)

    @Test("a drop over 4 h asks first and adds nothing until confirmed")
    func longAudioPerDrop() async throws {
        let h = try await Harness(durations: [Self.a: 5 * 3600])
        await h.viewModel.addFiles([Self.a])
        #expect(h.viewModel.confirmation == .longAudio(urls: [Self.a], hours: 5))
        #expect(h.viewModel.items.isEmpty)
        await h.viewModel.confirmLongAudio()
        await h.settle()
        #expect(h.viewModel.confirmation == nil)
        #expect(h.viewModel.items.count == 1)
    }

    @Test("cancelling the long-audio confirmation leaves the queue empty")
    func longAudioCancelled() async throws {
        let h = try await Harness(durations: [Self.a: 5 * 3600])
        await h.viewModel.addFiles([Self.a])
        #expect(h.viewModel.confirmation == .longAudio(urls: [Self.a], hours: 5))
        h.viewModel.cancelConfirmation()
        #expect(h.viewModel.confirmation == nil)
        await h.settle()
        #expect(h.viewModel.items.isEmpty)
    }

    // MARK: 2 — header title/subtitle (design 1c / MW-06x)

    @Test("header title/subtitle for 1 done, 2 need attention")
    func headerTexts() async throws {
        let h = try await Harness()
        await h.transcriber.script(Self.a, .failure(.decodeFailed("corrupt")))
        await h.transcriber.script(Self.b, .document(Self.doc(Self.b)))
        await h.viewModel.addFiles([Self.a, Self.b, Self.bad])   // bad fails on add (unsupported)
        await h.viewModel.transcribeAll()
        await h.settle()
        #expect(h.viewModel.headerTitle == "Queue · 3 files")
        // 2892 + 724 = 3616 s → hoursMinutes rounds to 60 min → "1 h" (not "1 h 0 min").
        #expect(FilesViewModel.hoursMinutes(3616) == "1 h")
        #expect(h.viewModel.headerSubtitle == "1 h of audio · 1 done · 2 need attention")
    }

    // MARK: 3 — transcribe button + needsModel

    @Test("transcribe button title reflects queued count and output format; needsModel blocks canTranscribe")
    func transcribeButton() async throws {
        let h = try await Harness()
        await h.viewModel.addFiles([Self.a, Self.b])
        await h.settle()
        #expect(h.viewModel.transcribeButtonTitle == "Transcribe 2 files as TXT")
        h.settings.outputFormat = .srt
        #expect(h.viewModel.transcribeButtonTitle == "Transcribe 2 files as SRT")
        #expect(h.viewModel.canTranscribe == true)

        let noModel = try await Harness(installedModel: false)
        await noModel.viewModel.addFiles([Self.a, Self.b])
        await noModel.settle()
        #expect(noModel.viewModel.needsModel == true)
        #expect(noModel.viewModel.canTranscribe == false)
        await noModel.viewModel.transcribeAll()
        #expect(await noModel.queue.isRunning == false)
    }

    // MARK: 4 — stop confirmation (MW-06c)

    @Test("requestStop confirms above 10% progress, cancels silently at or below it")
    func stopRule() async throws {
        let h = try await Harness()
        await h.transcriber.hold(Self.a)
        await h.transcriber.script(Self.a, .document(Self.doc(Self.a)))
        await h.viewModel.addFiles([Self.a])
        await h.settle()
        await h.viewModel.transcribeAll()
        await h.drainHeld(Self.a)

        let running = try #require(h.viewModel.items.first)
        #expect(running.status == .running(progress: 0.75))   // default progressSteps, all reported before parking

        await h.viewModel.requestStop(running)
        #expect(h.viewModel.confirmation == .stop(running, progress: 0.75))
        await h.viewModel.confirmStop()
        await h.settle()
        #expect(h.viewModel.confirmation == nil)
        #expect(h.viewModel.items.first?.status == .cancelled)

        let low = try await Harness()
        await low.transcriber.hold(Self.a)
        await low.transcriber.setProgressSteps([0.05])
        await low.transcriber.script(Self.a, .document(Self.doc(Self.a)))
        await low.viewModel.addFiles([Self.a])
        await low.settle()
        await low.viewModel.transcribeAll()
        await low.drainHeld(Self.a)

        let lowRunning = try #require(low.viewModel.items.first)
        await low.viewModel.requestStop(lowRunning)
        #expect(low.viewModel.confirmation == nil)   // no confirmation asked at/below the threshold
        await low.settle()
        #expect(low.viewModel.items.first?.status == .cancelled)
    }

    // MARK: 5 — auto-export and open (MW-06r)

    @Test("finishing a job auto-exports in the configured format; open/closeResult drive the result view")
    func autoExportAndOpen() async throws {
        let h = try await Harness()
        await h.transcriber.script(Self.a, .document(Self.doc(Self.a)))
        await h.viewModel.addFiles([Self.a])
        await h.settle()
        h.settings.outputFormat = .srt
        await h.viewModel.transcribeAll()
        await h.settle()

        let item = try #require(h.viewModel.items.first)
        guard case .done = item.status else { Issue.record("expected the job to be done"); return }

        let url = try #require(h.viewModel.exported(for: item))
        #expect(url.lastPathComponent == "interview-raw.srt")
        #expect(FileManager.default.fileExists(atPath: url.path))

        h.viewModel.open(item)
        #expect(h.viewModel.selected?.url == url)
        #expect(h.viewModel.selected?.item.id == item.id)
        h.viewModel.closeResult()
        #expect(h.viewModel.selected == nil)
    }

    // MARK: 6 — ETA throttle (design 3d)

    @Test("running progress renders at most once per second; etaText reflects the throttled rate")
    func etaThrottle() async throws {
        // Two running events inside the same throttle window: the estimator records both, but the
        // second never passes the once-per-second render gate, so etaText stays nil.
        // 0.3125 (5/16) is exactly representable in binary floating point, so the accumulated
        // "logical" timestamps below are exact — no rounding drift near the throttle boundary.
        let throttled = try await Harness(clockStep: 0.3125)
        await throttled.transcriber.hold(Self.a)
        await throttled.transcriber.setProgressSteps([0.25])
        await throttled.transcriber.script(Self.a, .document(Self.doc(Self.a)))
        await throttled.viewModel.addFiles([Self.a])
        await throttled.settle()
        await throttled.viewModel.transcribeAll()
        await throttled.drainHeld(Self.a)
        let item1 = try #require(throttled.viewModel.items.first)
        #expect(throttled.viewModel.etaText(for: item1) == nil)
        await throttled.transcriber.release(Self.a)
        await throttled.settle()

        // A third running event, once enough logical time has passed, clears the throttle and the
        // estimator now has a rate to report.
        let rendered = try await Harness(clockStep: 0.3125)
        await rendered.transcriber.hold(Self.a)
        await rendered.transcriber.setProgressSteps([0.25, 0.5])
        await rendered.transcriber.script(Self.a, .document(Self.doc(Self.a)))
        await rendered.viewModel.addFiles([Self.a])
        await rendered.settle()
        await rendered.viewModel.transcribeAll()
        await rendered.drainHeld(Self.a)
        let item2 = try #require(rendered.viewModel.items.first)
        #expect(item2.status == .running(progress: 0.5))
        #expect(rendered.viewModel.etaText(for: item2) == "about 2 s left")
        await rendered.transcriber.release(Self.a)
        await rendered.settle()
    }
}
