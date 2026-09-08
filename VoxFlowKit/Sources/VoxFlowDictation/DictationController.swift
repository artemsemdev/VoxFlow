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
    private var timers: [FlowBarTimer: Task<Void, Never>] = [:]
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
            Task { [loadModel] in
                do { try await loadModel(); self.handle(.modelLoaded) }
                catch { self.handle(.modelLoadFailed(String(describing: error))) }
            }
        case .startTimer(let id, let seconds):
            timers[id]?.cancel()
            timers[id] = Task { [clock] in
                do { try await clock.sleep(for: seconds) } catch { return }
                self.timerFired(id)
            }
        case .cancelTimer(let id): timers[id]?.cancel(); timers[id] = nil
        case .insert(let text):
            Task { [inserter] in
                let result = await inserter.insert(text)
                self.recordInsertion(result)
            }
        case .copyToClipboard(let text): copyToClipboard(text)
        case .saveHistory:
            if let result = lastResult { Task { [onSave, lastAppName] in await onSave(result, lastAppName) } }
        }
    }

    private func recordInsertion(_ result: InsertionResult) {
        if case .inserted(let app) = result { lastAppName = app }
        handle(.insertionFinished(result))
    }

    private func timerFired(_ id: FlowBarTimer) {
        guard timers[id] != nil else { return }      // cancelled between wake-up and delivery
        timers[id] = nil
        handle(.timer(id))
    }

    private func startCapture() {
        teardown()
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
        feed = continuation
        captureTask = Task { [microphone] in
            do {
                for try await event in microphone.start() {
                    if case .chunk(let chunk) = event { self.receive(chunk) }
                }
            } catch let error as MicrophoneError {
                self.handle(.microphoneFailed(error))
            } catch {
                self.handle(.microphoneFailed(.engineFailed(String(describing: error))))
            }
        }
        transcribeTask = Task { [transcriber, options] in
            do {
                let result = try await transcriber.transcribe(stream, options: options()) { event in await self.receive(event) }
                self.finished(result)
            } catch DictationError.cancelled {
            } catch {
                self.handle(.transcriptionFailed(String(describing: error)))
            }
        }
    }

    private func receive(_ chunk: AudioChunk) { feed?.yield(chunk); handle(.level(rms: chunk.rms)) }
    private func receive(_ event: DictationEvent) {
        switch event {
        case .language(let d): handle(.languageDetected(d))
        case .partialText(let t): handle(.partialText(t))
        }
    }
    private func finished(_ result: DictationResult) {
        lastResult = result
        handle(.transcriptReady(text: result.text, lowConfidence: result.lowConfidence))
    }

    private func teardown() {
        captureTask?.cancel(); captureTask = nil
        transcribeTask?.cancel(); transcribeTask = nil
        feed?.finish(); feed = nil
    }
}
