import Foundation
import VoxFlowCore

/// Insertion needs a fresh, privacy-checked target, without microphone or model preflight.
public enum ReinsertionTarget: Sendable, Equatable {
    case ready, excluded(String)
    /// The frontmost app changed during preparation; abandon this attempt without inserting.
    case changed
}

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
    /// Decides, once per capture, whether that capture's result should be treated as ephemeral (e.g.
    /// onboarding's Try It step or a History "scratchpad") — an ephemeral capture's `.saveHistory`
    /// effect is a no-op. Read exactly once, in `startCapture()`, and cached in `captureIsEphemeral`:
    /// a caller flipping the underlying condition mid-capture must not retroactively change what an
    /// already-in-flight capture does when it finishes. Defaulted so every existing call site keeps
    /// compiling unchanged.
    private let ephemeral: @Sendable () -> Bool

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
    /// Multi-subscriber fan-out for `results()`, same shape as `subscribers` above.
    private var resultSubscribers: [UUID: AsyncStream<DictationResult>.Continuation] = [:]
    public private(set) var lastResult: DictationResult?
    /// Session-only cache, independent of the history toggle and of a later aborted capture.
    private var lastCompletedResult: DictationResult?
    private var isReinserting = false
    private var isPreparingCapture = false
    private var lastAppName: String?
    /// A config set mid-dictation (`updateConfig` while not `.idle`) waits here rather than
    /// mutating the running machine's timers out from under it — applied the moment the machine
    /// next transitions to `.idle`, so a change to e.g. `silenceStop` never affects the timer
    /// already ticking for the dictation in progress.
    private var pendingConfig: FlowBarConfig?
    /// This capture's ephemeral decision, evaluated once by `startCapture()` (see `ephemeral`) and
    /// consulted by the `.saveHistory` effect. Reset by `teardown()` (so also by `startCapture()`,
    /// which calls it first) so a stale `true` can never leak into the next capture's save.
    private var captureIsEphemeral = false

    public init(config: FlowBarConfig, microphone: any MicrophoneCapturing, transcriber: any DictationTranscribing,
                inserter: any TextInserting, clock: any MonotonicClock,
                preflight: @escaping @Sendable () async -> Preflight,
                loadModel: @escaping @Sendable () async throws -> Void,
                options: @escaping @Sendable () -> TranscriptionOptions,
                onSave: @escaping SaveHandler,
                copyToClipboard: @escaping @Sendable (String) -> Void,
                ephemeral: @escaping @Sendable () -> Bool = { false }) {
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
        self.ephemeral = ephemeral
    }

    public var state: FlowBarState { machine.state }
    /// Exposed for tests and live-settings callers (`updateConfig` below is the only writer).
    public var config: FlowBarConfig { machine.config }

    /// Live-applies a settings change (e.g. silence-stop). Applied immediately when idle; while a
    /// dictation is in progress it's held and applied the moment the machine returns to `.idle`, so
    /// the change never perturbs a timer already running for that dictation.
    public func updateConfig(_ config: FlowBarConfig) {
        if machine.state == .idle {
            machine.config = config
        } else {
            pendingConfig = config
        }
    }

    /// Seconds since the current dictation started, from this controller's (monotonic) clock — nil
    /// outside `.listening`/`.processing`. History timestamps use `Date`; this is the HUD's own
    /// "00:12" elapsed counter and the two are not interchangeable (ADR-003).
    public var elapsed: TimeInterval? {
        switch machine.state {
        case .listening(let l): clock.now() - l.startedAt
        case .processing(let p): clock.now() - p.startedAt
        default: nil
        }
    }

    /// Every subscriber gets each state change after subscribing (not the current state).
    public func states() -> AsyncStream<FlowBarState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<FlowBarState>.makeStream(bufferingPolicy: .unbounded)
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        return stream
    }

    /// Like `states()`, but yields the current state into the stream before any changes — safe to
    /// subscribe *after* reading `state` without missing a change that lands in between (M3).
    public func currentAndChanges() -> AsyncStream<FlowBarState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<FlowBarState>.makeStream(bufferingPolicy: .unbounded)
        continuation.yield(machine.state)
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        return stream
    }
    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }

    /// Every completed capture's result, in order — fed from the same place `.saveHistory` invokes
    /// `onSave` (guarded by `!captureIsEphemeral`, exactly like `onSave`), *not* a second call site
    /// off `finished(_:capture:)`. That means a capture whose result is only copied to the clipboard
    /// because "Keep history" is off (`HistoryWriter.save` no-ops on that setting, after this method
    /// has already run) still produces a result here — an MCP `dictate` call observes exactly what a
    /// hotkey dictation produced, not only what got persisted.
    ///
    /// Same multi-subscriber fan-out as `currentAndChanges()`/`states()`: each call gets its own
    /// unbounded `AsyncStream`, registered in `resultSubscribers` synchronously (this method runs on
    /// the actor, so registration can't race a concurrent `.saveHistory` effect), and every
    /// subscriber's continuation is yielded to — once each — inside that single actor-isolated loop,
    /// so two concurrent subscribers see the same results, in the same order, with no drops (nothing
    /// is dropped: `.unbounded` buffers if a subscriber isn't awaiting `next()` yet) and no
    /// duplicates (each subscriber's continuation is yielded to exactly once per result). A
    /// subscriber's `onTermination` removes it from `resultSubscribers`, so a finished/cancelled
    /// subscriber is never retained or yielded to again — matching `removeSubscriber` for `states()`.
    ///
    /// Unlike `currentAndChanges()`, there is no "current result" to replay: a subscriber that
    /// arrives after a result was yielded misses it, so a caller (the `dictate` tool) must subscribe
    /// before starting the capture.
    public func results() -> AsyncStream<DictationResult> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<DictationResult>.makeStream(bufferingPolicy: .unbounded)
        resultSubscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeResultSubscriber(id) } }
        return stream
    }
    private func removeResultSubscriber(_ id: UUID) { resultSubscribers[id] = nil }

    public func fnDown() async { await activate(mode: nil) }
    public func fnUp() { handle(.fnUp) }
    public func shortcutDown(_ mode: HotkeyMode) async { await activate(mode: mode) }
    private func activate(mode: HotkeyMode?) async {
        guard !isReinserting, !isPreparingCapture else { return }
        // Preflight captures the insertion target. Only a start may replace that target; a stop
        // or an ignored dedicated shortcut must preserve the current capture's focus snapshot.
        var checks: Preflight?
        if mode == nil || canReinsert {
            isPreparingCapture = true
            let id = captureID
            checks = await preflight()
            isPreparingCapture = false
            guard id == captureID, !Task.isCancelled else { return }
        }
        if let mode { handle(.shortcutDown(mode, checks)) }
        else if let checks { handle(.fnDown(checks)) }
    }
    public func pushToTalkReleased() { handle(.pushToTalkReleased) }
    public func escape() {
        if isReinserting || isPreparingCapture { captureID &+= 1 }
        handle(.escape)
    }
    public func anyKey() { handle(.anyKey) }
    public func copyRaw() { handle(.copyRawRequested) }
    /// Escape can invalidate storage/target preparation. Dispatching `insert` is the commit point:
    /// the insertion protocol cannot roll back an edit already handed to the target application.
    @discardableResult
    public func reinsertLast(prepare: @Sendable () async -> ReinsertionTarget,
                             lastSaved: @Sendable () async -> DictationResult? = { nil }) async -> InsertionResult? {
        guard canReinsert, !isReinserting, !isPreparingCapture else { return nil }
        isReinserting = true
        defer { isReinserting = false }
        let id = captureID
        let cachedResult: DictationResult?
        if let lastCompletedResult { cachedResult = lastCompletedResult }
        else { cachedResult = await lastSaved() }
        guard let cachedResult, !cachedResult.text.isEmpty, id == captureID, canReinsert, !Task.isCancelled else { return nil }
        let target = await prepare()
        guard id == captureID, canReinsert, !Task.isCancelled else { return nil }
        guard target != .changed else { return nil }
        if case .excluded(let app) = target { handle(.reinsertionBlocked(app)); return nil }
        let result = await inserter.insert(cachedResult.text, cursorOffset: cachedResult.cursorOffset)
        guard id == captureID, canReinsert, !Task.isCancelled else { return result }
        handle(.reinsertionFinished(text: cachedResult.text, result: result))
        return result
    }
    private var canReinsert: Bool { machine.state == .idle || machine.state.isDismissable }
    /// FB-09: pause dictation from the menu bar or the Flow Bar pill.
    public func pause(for seconds: TimeInterval) { handle(.pause(seconds: seconds)) }
    public func resume() { handle(.resume) }
    /// This controller's (monotonic) clock's "until" — `nil` outside `.paused`.
    public var pausedUntil: TimeInterval? {
        if case .paused(let until) = machine.state { until } else { nil }
    }

    private func handle(_ event: FlowBarEvent) {
        let before = machine.state
        let effects = machine.handle(event, now: clock.now())
        if machine.state != before {
            if machine.state == .idle, let pendingConfig {
                machine.config = pendingConfig
                self.pendingConfig = nil
            }
            for c in subscribers.values { c.yield(machine.state) }
        }
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
            let cursorOffset = lastResult?.cursorOffset
            Task {
                let result = await self.inserter.insert(text, cursorOffset: cursorOffset)
                self.recordInsertion(result, capture: id)
            }
        case .copyToClipboard(let text): copyToClipboard(text)
        case .saveHistory:
            // Snapshot `lastAppName` now: it's read again (and reset) by the *next* `startCapture`,
            // which must not change what this already-in-flight save reports. An ephemeral capture
            // (Try It, a History scratchpad) skips the save entirely — silently, not logged: this is
            // the expected, common path for those captures, not an error condition.
            if let result = lastResult, !captureIsEphemeral {
                lastCompletedResult = result
                let appName = lastAppName
                // See `results()`'s doc comment: broadcast here, alongside `onSave`, not from a
                // second call site — this is the one place a finished, non-ephemeral capture's
                // result is known.
                for c in resultSubscribers.values { c.yield(result) }
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
        // Evaluated exactly once per capture, alongside `captureID` — see `ephemeral`'s doc comment.
        captureIsEphemeral = ephemeral()
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
        captureIsEphemeral = false
        captureTask?.cancel(); captureTask = nil
        transcribeTask?.cancel(); transcribeTask = nil
        feed?.finish(); feed = nil
    }
}
