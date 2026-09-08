import Foundation
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowFiles
import VoxFlowModels
import VoxFlowTestSupport
@testable import VoxFlow

/// Deterministic, lock-guarded clock for the view model's injected `now:` closure. Time only moves
/// when a test says so:
/// - `advance(by:)` is the explicit, test-driven way to make time pass — used directly by
///   `etaThrottle` so the once-per-second render throttle (design 3d) can be exercised without
///   depending on real wall-clock timing or counting how many times `now()` happens to be called.
/// - `step` (opt-in, defaults to 0 — i.e. frozen) additionally advances the clock on every `now()`
///   read; the harness uses a small non-zero default so ordinary tests that just want "progress is
///   never throttled" (e.g. `stopRule`) don't have to reason about the throttle at all.
final class TestClock: Sendable {
    private let state: Mutex<Date>
    private let step: TimeInterval

    init(start: Date = Date(timeIntervalSince1970: 0), step: TimeInterval = 0) {
        state = Mutex(start)
        self.step = step
    }

    func now() -> Date {
        state.withLock { date in
            let current = date
            if step != 0 { date.addTimeInterval(step) }
            return current
        }
    }

    /// Moves the clock forward (or, with a negative value, backward) by `seconds`, independent of
    /// `step`. This is the mechanism `etaThrottle` uses to drive time explicitly.
    func advance(by seconds: TimeInterval) {
        state.withLock { $0.addTimeInterval(seconds) }
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
        let exports: ExportCoordinator
        let viewModel: FilesViewModel

        /// `clockStep` defaults to 2 s per `now()` call, comfortably above the 1 s render throttle
        /// so ordinary tests always see the latest progress in `items`; `etaThrottle` overrides it
        /// (to 0, i.e. frozen) and drives time explicitly via `clock.advance(by:)` instead.
        /// `preSeed` adds URLs to the queue *before* the view model — and therefore its subscription
        /// and seed read — exist, so the row can only ever reach `items` via the initial seed.
        /// `exportDirectory` overrides the auto-export destination (default: a fresh subdirectory).
        init(durations: [URL: TimeInterval] = [a: 2892, b: 724], installedModel: Bool = true, clockStep: TimeInterval = 2,
             preSeed: [URL] = [], exportDirectory: URL? = nil) async throws {
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
            if !preSeed.isEmpty { await queue.add(preSeed) }
            let exportDir = exportDirectory ?? dir.file("Transcripts")
            clock = TestClock(step: clockStep)
            exports = ExportCoordinator(queue: queue, settings: settings, exporter: { TranscriptExporter(directory: exportDir) })
            viewModel = FilesViewModel(queue: queue, settings: settings, modelStore: store, durations: self.durations,
                                       exports: exports, now: clock.now)
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

    // MARK: Lifecycle / seeding

    @Test("the view model deallocates once nothing else holds it — no retain cycle through the event task")
    func deallocatesWhenReleased() async throws {
        weak var weakViewModel: FilesViewModel?
        do {
            let h = try await Harness()
            weakViewModel = h.viewModel
            #expect(weakViewModel != nil)
        }
        // `h` (and its last strong reference to the view model) is out of scope now; give the
        // runtime a bounded number of turns to actually run the deallocation — ARC release itself
        // is synchronous, but this keeps the check honest about not asserting on the same line.
        for _ in 0..<50 { await Task.yield() }
        #expect(weakViewModel == nil)
    }

    @Test("seeding from queue.items doesn't double-count a row that already existed before construction")
    func seedDoesNotDuplicate() async throws {
        let h = try await Harness(preSeed: [Self.a])
        await h.settle()
        #expect(h.viewModel.items.count == 1)
        #expect(h.viewModel.items.first?.url == Self.a)
    }

    // MARK: 1 — long audio confirmation (3e)

    @Test("a drop over 4 h asks first and adds nothing until confirmed")
    func longAudioPerDrop() async throws {
        let h = try await Harness(durations: [Self.a: 5 * 3600.0])
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
        let h = try await Harness(durations: [Self.a: 5 * 3600.0])
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

    @Test("requestStop consults live queue progress even when the caller's item snapshot is stale")
    func requestStopUsesLiveProgress() async throws {
        let h = try await Harness()
        await h.transcriber.hold(Self.a)
        await h.transcriber.script(Self.a, .document(Self.doc(Self.a)))
        await h.viewModel.addFiles([Self.a])
        await h.settle()
        let staleItem = try #require(h.viewModel.items.first)   // captured while still `.queued`
        #expect(staleItem.status == .queued)

        await h.viewModel.transcribeAll()
        await h.drainHeld(Self.a)   // the live queue is now at 0.75; `staleItem` still says `.queued`

        await h.viewModel.requestStop(staleItem)
        #expect(h.viewModel.confirmation == .stop(staleItem, progress: 0.75))
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

    @Test("a failed export surfaces via exportError(for:) after .finished")
    func exportErrorSurfaces() async throws {
        let outerDir = TemporaryDirectory()
        let blockedPath = outerDir.file("Transcripts")
        try Data("not a directory".utf8).write(to: blockedPath)   // a plain file where the exporter needs a directory
        let h = try await Harness(exportDirectory: blockedPath)
        await h.transcriber.script(Self.a, .document(Self.doc(Self.a)))
        await h.viewModel.addFiles([Self.a])
        await h.settle()
        await h.viewModel.transcribeAll()
        await h.settle()

        let item = try #require(h.viewModel.items.first)
        guard case .done = item.status else { Issue.record("expected the job to be done"); return }
        #expect(h.viewModel.exported(for: item) == nil)
        #expect(h.viewModel.exportError(for: item) != nil)
    }

    @Test("retry refreshes model state first and won't start the queue when no model is installed")
    func retryGuardsOnNeedsModel() async throws {
        let h = try await Harness(installedModel: false)
        await h.transcriber.script(Self.a, .failure(.decodeFailed("corrupt")))
        await h.viewModel.addFiles([Self.a])
        await h.settle()
        await h.queue.start()   // bypass the view model's own needsModel guard to get a failed row
        await h.settle()
        let item = try #require(h.viewModel.items.first)
        #expect(item.status == .failed(.decodeFailed("corrupt")))

        await h.viewModel.retry(item)
        await h.settle()
        #expect(h.viewModel.needsModel == true)
        #expect(await h.queue.isRunning == false)
        #expect(h.viewModel.items.first?.status == .queued)   // re-queued by retry, but never started
    }

    @Test("headerSubtitle omits the duration clause once it rounds down to 0 min")
    func headerSubtitleOmitsNegligibleDuration() async throws {
        let h = try await Harness(durations: [Self.a: 10])   // 10 s rounds to 0 min
        await h.viewModel.addFiles([Self.a])
        await h.settle()
        #expect(h.viewModel.headerSubtitle == "")
    }

    // MARK: 6 — ETA throttle (design 3d)

    @Test("running progress renders at most once per second; etaText reflects the throttled rate")
    func etaThrottle() async throws {
        // Throttled case: a frozen clock (`clockStep: 0`) means the second running event reads the
        // *exact same* "now" as the first, so it can never look like a second has elapsed — that
        // holds regardless of how many of the two events the drain below has actually applied by
        // the time we check, which is what makes this deterministic without racing the drain.
        // `advance(by:)` — not a per-call step, and not real time — is what moves this clock at all;
        // the call below just establishes an arbitrary non-zero starting point to prove it's used.
        let throttled = try await Harness(clockStep: 0)
        throttled.clock.advance(by: 5)
        await throttled.transcriber.hold(Self.a)
        await throttled.transcriber.setProgressSteps([0.25])
        await throttled.transcriber.script(Self.a, .document(Self.doc(Self.a)))
        await throttled.viewModel.addFiles([Self.a])
        await throttled.settle()
        await throttled.viewModel.transcribeAll()
        await throttled.drainHeld(Self.a)
        let item1 = try #require(throttled.viewModel.items.first)
        // The throttled 0.25 update never reached `items` — proof, not just an assumption, that it
        // really was throttled and not merely "hasn't happened yet".
        #expect(item1.status == .running(progress: 0))
        #expect(throttled.viewModel.etaText(for: item1) == nil)
        await throttled.transcriber.release(Self.a)
        await throttled.settle()

        // Renders case: `FakeFileTranscriber.hold` offers exactly one pause point per job — after
        // every scripted progress step, right before the result returns — so there is no seam to
        // call `clock.advance(by:)` strictly *between* two of this single job's progress reports
        // without racing the drain that applies them. `clockStep` (time passing on every `now()`
        // read) stands in for that here; `apply` reads the clock exactly once per `.changed` event,
        // so with step `s` the three running events land at t=0, t=s, t=2s. 0.875 (7/8) is exactly
        // representable in binary floating point, so those timestamps (0, 0.875, 1.75) are exact —
        // no rounding drift near the throttle boundary. This still verifies end to end: the second
        // event (t=0.875, < 1 s since the first) stays throttled, and the third (t=1.75, ≥ 1 s since
        // the first, since the second's throttled render never moved that baseline) both clears the
        // throttle *and* its reported rate reflects all three recorded samples (0 at t=0, 0.25 at
        // t=0.875, 0.5 at t=1.75 → rate 2/7 progress/s → 1.75 s remaining → "about 2 s left").
        let rendered = try await Harness(clockStep: 0.875)
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

    // MARK: progressText (I5 — "Preparing…" below 5%)

    @Test("progressText reads Preparing… below 5% and a rounded percentage above it")
    func progressTextPreparingBelowThreshold() {
        #expect(FilesViewModel.progressText(for: 0) == "Preparing…")
        #expect(FilesViewModel.progressText(for: 0.049) == "Preparing…")
        #expect(FilesViewModel.progressText(for: 0.05) == "5%")
        #expect(FilesViewModel.progressText(for: 0.72) == "72%")
    }

    // MARK: 7 — failure copy (MW-06x)

    @Test("failureMessage matches the MW-06x copy; unsupported type offers no Retry")
    func failureCopy() {
        #expect(FilesViewModel.failureMessage(.decodeFailed("corrupt")) ==
                "Couldn\u{2019}t decode this file — it may be incomplete or corrupt.")
        #expect(FilesViewModel.failureMessage(.unsupportedType("pages")) ==
                "Not an audio or video file. Supported: MP3, WAV, M4A, AAC, FLAC, MP4, MOV.")
        #expect(FilesViewModel.canRetryFailure(.decodeFailed("corrupt")) == true)
        #expect(FilesViewModel.canRetryFailure(.engineFailed("x")) == true)
        #expect(FilesViewModel.canRetryFailure(.noModelInstalled) == true)
        #expect(FilesViewModel.canRetryFailure(.unsupportedType("pages")) == false)
        #expect(FilesViewModel.isUnsupportedFailure(.unsupportedType("pages")) == true)
        #expect(FilesViewModel.isUnsupportedFailure(.decodeFailed("corrupt")) == false)
    }

    // MARK: 8 — alert copy (MW-06c stop confirmation, 3e long-audio confirmation)

    @Test("stop/long-audio alert copy matches the design's exact wording")
    func alertCopy() async throws {
        let h = try await Harness()
        await h.viewModel.addFiles([Self.a])   // Self.a → "interview-raw.m4a", the design's own example
        await h.settle()
        let item = try #require(h.viewModel.items.first)

        #expect(FilesViewModel.stopAlertTitle(for: item) == "Stop transcribing \u{201C}interview-raw.m4a\u{201D}?")
        #expect(FilesViewModel.stopAlertMessage(progress: 0.72) ==
                "It\u{2019}s 72% done. The partial transcript will be discarded and the file stays in the queue.")
        #expect(FilesViewModel.longAudioAlertTitle(hours: 5.0) == "Transcribe 5 h of audio?")   // whole hours: no decimal (M3)
        #expect(FilesViewModel.longAudioAlertTitle(hours: 4.5) == "Transcribe 4.5 h of audio?")   // fractional: one decimal place
        #expect(FilesViewModel.longAudioAlertMessage(hours: 5.0) == "About 19 min on this Mac.")
    }
}
