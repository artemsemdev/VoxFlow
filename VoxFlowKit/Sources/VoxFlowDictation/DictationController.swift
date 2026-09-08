import Foundation
import VoxFlowCore

/// Drives `FlowBarMachine`: owns the mic/transcriber/timer tasks and publishes states for the HUD.
public actor DictationController {
    public typealias SaveHandler = @Sendable (DictationResult, String?) async -> Void

    private var machine: FlowBarMachine
    private let microphone: any MicrophoneCapturing
    private let transcriber: any DictationTranscribing
    private let inserter: any TextInserting
    private let clock: any MonotonicClock
    private let preflight: @Sendable () async -> Preflight
    private let loadModel: @Sendable () async throws -> Void
    private let options: @Sendable () -> TranscriptionOptions
    private let onSave: SaveHandler
    private let copyToClipboard: @Sendable (String) -> Void

    private var feed: AsyncStream<AudioChunk>.Continuation?
    private var captureTask: Task<Void, Never>?
    private var transcribeTask: Task<Void, Never>?
    /// Bumped by `teardown()` (so also by `startCapture()`, which calls it first): invalidates every
    /// callback still in flight from a torn-down capture, so a stale mic chunk, transcript, insertion,
    /// or mic/transcription failure from an aborted dictation can never reach a newer one.
    private var captureID: UInt64 = 0
    /// One id per `.startTimer`/`.cancelTimer` registration for `id`: `timerFired` only acts when the
    /// generation it was created with still matches, so a timer whose `sleep` already returned when it
    /// gets superseded by a fresh same-id registration can't fire in the new registration's place.
    private var timers: [FlowBarTimer: (generation: UInt64, task: Task<Void, Never>)] = [:]
    private var nextTimerGeneration: UInt64 = 0
    private var subscribers: [UUID: AsyncStream<FlowBarState>.Continuation] = [:]
    public private(set) var lastResult: DictationResult?
    private var lastAppName: String?

    public init(config: FlowBarConfig, microphone: any MicrophoneCapturing, transcriber: any DictationTranscribing,
                inserter: any TextInserting, clock: any MonotonicClock,
                preflight: @escaping @Sendable () async -> Preflight,
                loadModel: @escaping @Sendable () async throws -> Void,
                options: @escaping @Sendable () -> TranscriptionOptions,
                onSave: @escaping SaveHandler,
                copyToClipboard: @escaping @Sendable (String) -> Void) {
        machine = FlowBarMachine(config: config)
        self.microphone = microphone
        self.transcriber = transcriber
        self.inserter = inserter
        self.clock = clock
        self.preflight = preflight
        self.loadModel = loadModel
        self.options = options
        self.onSave = onSave
        self.copyToClipboard = copyToClipboard
    }

    public var state: FlowBarState { machine.state }

    /// Every subscriber gets each state change after subscribing (not the current state).
    public func states() -> AsyncStream<FlowBarState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<FlowBarState>.makeStream(bufferingPolicy: .unbounded)
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        return stream
    }
    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }

    public func fnDown() async { handle(.fnDown(await preflight())) }
    public func fnUp() { handle(.fnUp) }
    public func escape() { handle(.escape) }
    public func anyKey() { handle(.anyKey) }
    public func copyRaw() { handle(.copyRawRequested) }

    private func handle(_ event: FlowBarEvent) {
        let before = machine.state
        let effects = machine.handle(event, now: clock.now())
        if machine.state != before { for c in subscribers.values { c.yield(machine.state) } }
        for effect in effects { run(effect) }
    }

    private func run(_ effect: FlowBarEffect) {
        switch effect {
        case .startCapture: startCapture()
        case .finishCapture: captureTask?.cancel(); captureTask = nil; feed?.finish(); feed = nil
        case .abortCapture: teardown(); lastResult = nil
        case .loadModel:
            Task {
                do { try await self.loadModel(); self.handle(.modelLoaded) }
                catch { self.handle(.modelLoadFailed(String(describing: error))) }
            }
        case .startTimer(let id, let seconds):
            timers[id]?.task.cancel()
            let generation = nextTimerGeneration
            nextTimerGeneration &+= 1
            timers[id] = (generation, Task {
                do { try await self.clock.sleep(for: seconds) } catch { return }
                self.timerFired(id, generation)
            })
        case .cancelTimer(let id): timers[id]?.task.cancel(); timers[id] = nil
        case .insert(let text):
            let id = captureID
            Task {
                let result = await self.inserter.insert(text)
                self.recordInsertion(result, capture: id)
            }
        case .copyToClipboard(let text): copyToClipboard(text)
        case .saveHistory:
            // Snapshot `lastAppName` now: it's read again (and reset) by the *next* `startCapture`,
            // which must not change what this already-in-flight save reports.
            if let result = lastResult {
                let appName = lastAppName
                Task { await self.onSave(result, appName) }
            }
        }
    }

    private func recordInsertion(_ result: InsertionResult, capture id: UInt64) {
        guard id == captureID else { return }
        lastAppName = if case .inserted(let app) = result { app } else { nil }
        handle(.insertionFinished(result))
    }

    private func timerFired(_ id: FlowBarTimer, _ generation: UInt64) {
        // Stale if cancelled outright (no entry) or if a fresh same-id registration replaced it.
        guard let entry = timers[id], entry.generation == generation else { return }
        timers[id] = nil
        handle(.timer(id))
    }

    private func startCapture() {
        teardown()
        lastAppName = nil
        let id = captureID
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
        feed = continuation
        captureTask = Task {
            do {
                for try await event in self.microphone.start() {
                    guard !Task.isCancelled, self.captureID == id else { break }
                    if case .chunk(let chunk) = event { self.receive(chunk, capture: id) }
                }
            } catch let error as MicrophoneError {
                self.microphoneFailed(error, capture: id)
            } catch {
                self.microphoneFailed(.engineFailed(String(describing: error)), capture: id)
            }
        }
        transcribeTask = Task {
            do {
                let result = try await self.transcriber.transcribe(stream, options: self.options()) { event in await self.receive(event, capture: id) }
                self.finished(result, capture: id)
            } catch DictationError.cancelled {
            } catch {
                self.transcriptionFailed(String(describing: error), capture: id)
            }
        }
    }

    private func receive(_ chunk: AudioChunk, capture id: UInt64) {
        guard id == captureID else { return }
        feed?.yield(chunk); handle(.level(rms: chunk.rms))
    }
    private func receive(_ event: DictationEvent, capture id: UInt64) {
        guard id == captureID else { return }
        switch event {
        case .language(let d): handle(.languageDetected(d))
        case .partialText(let t): handle(.partialText(t))
        }
    }
    private func finished(_ result: DictationResult, capture id: UInt64) {
        guard id == captureID else { return }
        lastResult = result
        handle(.transcriptReady(text: result.text, lowConfidence: result.lowConfidence))
    }
    private func microphoneFailed(_ error: MicrophoneError, capture id: UInt64) {
        guard id == captureID else { return }
        handle(.microphoneFailed(error))
    }
    private func transcriptionFailed(_ description: String, capture id: UInt64) {
        guard id == captureID else { return }
        handle(.transcriptionFailed(description))
    }

    private func teardown() {
        captureID &+= 1   // invalidates every callback still in flight from the old capture
        captureTask?.cancel(); captureTask = nil
        transcribeTask?.cancel(); transcribeTask = nil
        feed?.finish(); feed = nil
    }
}
