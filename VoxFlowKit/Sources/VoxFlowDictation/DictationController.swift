import Foundation
import Synchronization
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
    private let microphoneUse: any MicrophoneUseMonitoring
    private let transcriber: any DictationTranscribing
    private let inserter: any TextInserting
    private let clock: any MonotonicClock
    private let preflight: @Sendable () async -> Preflight
    private let loadModel: @Sendable () async throws -> Void
    private let options: @Sendable () -> TranscriptionOptions
    private let onSave: SaveHandler
    private let copyToClipboard: @Sendable (String) -> Void
    private let retryExpiryTaskFactory: @Sendable (@escaping @Sendable () async -> Void) -> Task<Void, Never>
    /// Decides, once per capture, whether that capture's result should be treated as ephemeral (e.g.
    /// onboarding's Try It step or a History "scratchpad") — an ephemeral capture's `.saveHistory`
    /// effect is a no-op. Read exactly once, in `startCapture()`, and cached in `captureIsEphemeral`:
    /// a caller flipping the underlying condition mid-capture must not retroactively change what an
    /// already-in-flight capture does when it finishes. Defaulted so every existing call site keeps
    /// compiling unchanged.
    private let ephemeral: @Sendable () -> Bool

    private var feed: AsyncStream<AudioChunk>.Continuation?
    private var processingDeadline: CaptureDeadline?
    private var captureTask: Task<Void, Never>?
    private var transcribeTask: Task<Void, Never>?
    private var insertionTask: Task<Void, Never>?
    private var liveValidity: CaptureValidity?
    private var liveContext: LiveInsertionContext?
    private var modelLoadTask: (capture: UInt64, generation: UInt64, task: Task<Void, Never>)?
    private var nextModelLoadGeneration: UInt64 = 0
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
    private var deviceSubscribers: [UUID: AsyncStream<String?>.Continuation] = [:]
    public private(set) var lastResult: DictationResult?
    /// Session-only cache, independent of the history toggle and of a later aborted capture.
    private var lastCompletedResult: DictationResult?
    private var isReinserting = false
    private var isPreparingCapture = false
    private var retryIntent: MicrophoneRetryIntent
    private var retryWatch: Task<Void, Never>?
    private var retryExpiry: Task<Void, Never>?
    private var retryGeneration: UInt64 = 0
    private var waitingForMicrophone = false
    private var pendingActivationID: UInt64?
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
                ephemeral: @escaping @Sendable () -> Bool = { false },
                microphoneUse: any MicrophoneUseMonitoring = UnmonitoredMicrophoneUse(),
                retryExpiryTaskFactory: @escaping @Sendable (
                    @escaping @Sendable () async -> Void
                ) -> Task<Void, Never> = { operation in
                    Task { await operation() }
                }) {
        machine = FlowBarMachine(config: config)
        retryIntent = MicrophoneRetryIntent(config: config)
        self.microphone = microphone
        self.microphoneUse = microphoneUse
        self.transcriber = transcriber
        self.inserter = inserter
        self.clock = clock
        self.preflight = preflight
        self.loadModel = loadModel
        self.options = options
        self.onSave = onSave
        self.copyToClipboard = copyToClipboard
        self.ephemeral = ephemeral
        self.retryExpiryTaskFactory = retryExpiryTaskFactory
    }

    private var terminationPending = false

    /// Atomically reports pending work and prevents a suspended preflight or a fresh hotkey/MCP
    /// request from starting another recording while the user is deciding or files are draining.
    public func beginTermination() -> Bool {
        let busy = machine.state.hasUnfinishedCapture || isPreparingCapture || isReinserting || !historySaves.isEmpty
        terminationPending = true
        if isPreparingCapture || isReinserting { captureID &+= 1 }
        stopMicrophoneWait(clearIntent: true)
        return busy
    }

    public func cancelTermination() { terminationPending = false }

    private var historySaves: [UUID: Task<Void, Never>] = [:]

    /// Flushes the active recording and waits for insertion and durable history before quit.
    public func finishForTermination() async {
        let changes = currentAndChanges()
        handle(.finishRequested)
        for await state in changes {
            if !state.hasUnfinishedCapture { break }
        }
        for save in historySaves.values { await save.value }
    }

    public var hasPendingHistorySave: Bool { !historySaves.isEmpty }

    public var state: FlowBarState { machine.state }
    /// A causal barrier for lifecycle tests; callers cannot replace or cancel the task.
    var activeModelLoadTask: Task<Void, Never>? { modelLoadTask?.task }
    /// Exposed for tests and live-settings callers (`updateConfig` below is the only writer).
    public var config: FlowBarConfig { machine.config }

    /// Live-applies a settings change (e.g. silence-stop). Applied immediately when idle; while a
    /// dictation is in progress it's held and applied the moment the machine returns to `.idle`, so
    /// the change never perturbs a timer already running for that dictation.
    public func updateConfig(_ config: FlowBarConfig) {
        if machine.state == .idle {
            machine.config = config
            retryIntent = MicrophoneRetryIntent(config: config)
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

    public func deviceChanges() -> AsyncStream<String?> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<String?>.makeStream(bufferingPolicy: .unbounded)
        deviceSubscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeDeviceSubscriber(id) }
        }
        return stream
    }
    private func removeDeviceSubscriber(_ id: UUID) { deviceSubscribers[id] = nil }

    public func fnDown() async {
        guard !terminationPending else { return }
        if updateWaitingInput(.fnDown) { return }
        await activate(mode: nil)
    }
    public func fnUp() {
        let waiting = updateWaitingInput(.fnUp)
        if !waiting { handle(.fnUp) }
    }
    public func shortcutDown(_ mode: HotkeyMode) async {
        guard !terminationPending else { return }
        if hasBlockedGesture, retryIntent.isReplacementShortcut(mode) {
            stopMicrophoneWait(clearIntent: true)
            captureID &+= 1
            retryIntent.begin(mode: mode, at: clock.now())
            if isPreparingCapture { pendingActivationID = captureID }
            else { await prepareCapture() }
            return
        }
        if updateWaitingInput(.shortcutDown(mode)) { return }
        await activate(mode: mode)
    }
    private func activate(mode: HotkeyMode?) async {
        guard !isReinserting, !isPreparingCapture else { return }
        // Only a start may replace the insertion target; continuations preserve its snapshot.
        if canReinsert {
            captureID &+= 1
            pendingActivationID = nil
            retryIntent.begin(mode: mode, at: clock.now())
            await prepareCapture()
        } else if let mode { handle(.shortcutDown(mode, nil)) }
        else { handle(.fnDown(nil)) }
    }
    private func prepareCapture() async {
        isPreparingCapture = true
        let id = captureID
        let checks = await preflight()
        finishPreparingCapture()
        guard id == captureID, !Task.isCancelled,
              let activation = retryIntent.activation(at: clock.now()) else { return }
        resumeMicrophone(checks, activation: activation)
    }

    private func finishPreparingCapture() {
        isPreparingCapture = false
        guard let id = pendingActivationID else { return }
        // The old preflight may ignore cancellation. Drain it before preparing a new target,
        // then use a new task so its cancellation cannot cancel the replacement activation.
        Task {
            guard self.pendingActivationID == id, self.captureID == id,
                  !self.isPreparingCapture, !self.isReinserting else { return }
            self.pendingActivationID = nil
            await self.prepareCapture()
        }
    }

    private var hasBlockedGesture: Bool {
        if waitingForMicrophone || pendingActivationID != nil { return true }
        if case .micUnavailable(.inUse) = machine.state { return isPreparingCapture }
        return false
    }

    public func pushToTalkReleased() {
        let waiting = updateWaitingInput(.pushToTalkReleased)
        if !waiting { handle(.pushToTalkReleased) }
    }
    public func escape() {
        if isReinserting || isPreparingCapture { captureID &+= 1 }
        if !updateWaitingInput(.cancel) { handle(.escape) }
    }
    public func anyKey() {
        if hasBlockedGesture || machine.state.isDismissable {
            if updateWaitingInput(.cancel) { return }
        }
        handle(.anyKey)
    }
    public func copyRaw() { handle(.copyRawRequested) }
    /// Escape can invalidate storage/target preparation. Dispatching `insert` is the commit point:
    /// the insertion protocol cannot roll back an edit already handed to the target application.
    @discardableResult
    public func reinsertLast(prepare: @Sendable () async -> ReinsertionTarget,
                             lastSaved: @Sendable () async -> DictationResult? = { nil }) async -> InsertionResult? {
        guard !terminationPending, canReinsert, !isReinserting, !isPreparingCapture else { return nil }
        isReinserting = true
        defer { isReinserting = false }
        let watch = retryWatch
        stopMicrophoneWait(clearIntent: true)
        captureID &+= 1
        let id = captureID
        await watch?.value // No preflight is running: only drain cancellation of the observer.
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
    public func pause(for seconds: TimeInterval) {
        if machine.state == .idle || machine.state.isDismissable {
            retryIntent.update(.cancel, at: clock.now())
            stopMicrophoneWait(clearIntent: true)
        }
        handle(.pause(seconds: seconds))
    }
    public func resume() { handle(.resume) }
    /// This controller's (monotonic) clock's "until" — `nil` outside `.paused`.
    public var pausedUntil: TimeInterval? {
        if case .paused(let until) = machine.state { until } else { nil }
    }

    private func handle(_ event: FlowBarEvent) {
        let before = machine.state
        let effects = machine.handle(event, now: clock.now())
        publish(effects, from: before)
    }

    private func resumeMicrophone(_ checks: Preflight, activation: MicrophoneRetryIntent.Activation) {
        let before = machine.state
        let effects = machine.resumeMicrophone(checks, activation: activation, now: clock.now())
        publish(effects, from: before)
    }

    private func publish(_ effects: [FlowBarEffect], from before: FlowBarState) {
        if machine.state != before {
            if machine.state == .idle, let pendingConfig {
                machine.config = pendingConfig
                retryIntent = MicrophoneRetryIntent(config: pendingConfig)
                self.pendingConfig = nil
            }
            for c in subscribers.values { c.yield(machine.state) }
        }
        for effect in effects { run(effect) }
        if case .micUnavailable(.inUse) = machine.state { beginMicrophoneWait() }
    }

    /// Returns whether this input belongs to an existing blocked gesture, including its stop.
    private func updateWaitingInput(_ input: MicrophoneRetryIntent.Input) -> Bool {
        let wasWaiting = hasBlockedGesture
        retryIntent.update(input, at: clock.now())
        guard wasWaiting else { return false }
        guard retryIntent.activation(at: clock.now()) != nil else {
            stopMicrophoneWait(clearIntent: true)
            handle(.anyKey)
            return true
        }
        scheduleRetryExpiry()
        return true
    }

    private func beginMicrophoneWait() {
        guard retryIntent.activation(at: clock.now()) != nil else { return }
        run(.cancelTimer(.dismiss)) // A live retry must not outlast an invisible error pill.
        guard !waitingForMicrophone else { return }
        waitingForMicrophone = true
        retryGeneration &+= 1
        let generation = retryGeneration
        let stream = microphoneUse.changes() // Subscribe before the snapshot to avoid a release gap.
        let initial = microphoneUse.currentState()
        retryWatch = Task {
            await self.microphoneUseChanged(initial, generation: generation)
            for await value in stream {
                guard self.waitingForMicrophone, self.retryGeneration == generation, !Task.isCancelled else { break }
                await self.microphoneUseChanged(value, generation: generation)
            }
            if self.waitingForMicrophone, self.retryGeneration == generation {
                self.stopMicrophoneWait(clearIntent: true)
                self.run(.startTimer(.dismiss, seconds: self.machine.config.dismissError))
            }
        }
        scheduleRetryExpiry()
    }

    private func scheduleRetryExpiry() {
        retryExpiry?.cancel()
        retryExpiry = nil
        guard let deadline = retryIntent.expiresAt else { return }
        let generation = retryGeneration
        retryExpiry = retryExpiryTaskFactory {
            let delay = deadline - self.clock.now()
            if delay > 0 {
                do { try await self.clock.sleep(for: delay) } catch { return }
            }
            await self.retryExpiryFired(deadline: deadline, generation: generation)
        }
    }

    private func retryExpiryFired(deadline: TimeInterval, generation: UInt64) {
        guard waitingForMicrophone, retryGeneration == generation,
              retryIntent.expiresAt == deadline else { return }
        stopMicrophoneWait(clearIntent: true)
        handle(.anyKey)
    }

    private func stopMicrophoneWait(clearIntent: Bool) {
        waitingForMicrophone = false
        retryGeneration &+= 1
        retryWatch?.cancel(); retryWatch = nil
        retryExpiry?.cancel(); retryExpiry = nil
        if clearIntent {
            pendingActivationID = nil
            retryIntent.update(.cancel, at: clock.now())
        }
    }

    private func microphoneUseChanged(_ value: MicrophoneUseState, generation: UInt64) async {
        guard waitingForMicrophone, retryGeneration == generation, !Task.isCancelled else { return }
        if case .inUse(let name) = value {
            let before = machine.state
            machine.state = .micUnavailable(.inUse(by: name))
            publish([], from: before)
            return
        }
        guard value == .available, !isPreparingCapture,
              let ticket = retryIntent.claim(at: clock.now()) else { return }
        isPreparingCapture = true
        let id = captureID
        let checks = await preflight()
        finishPreparingCapture()
        guard waitingForMicrophone, retryGeneration == generation, id == captureID, !Task.isCancelled else { return }
        guard let activation = retryIntent.consume(ticket, at: clock.now()) else {
            if retryIntent.activation(at: clock.now()) == nil {
                stopMicrophoneWait(clearIntent: true)
                handle(.anyKey)
            } else {
                // A second tap may have superseded the suspended claim without another hardware
                // notification. Retry its new intent after the earlier preflight has drained.
                await microphoneUseChanged(microphoneUse.freshState(), generation: generation)
            }
            return
        }
        if case .inUse = checks.microphone {
            retryIntent.rearm() // A new busy result permits the next real holder release.
            resumeMicrophone(checks, activation: activation)
            return
        }
        stopMicrophoneWait(clearIntent: false)
        resumeMicrophone(checks, activation: activation)
    }

    private func run(_ effect: FlowBarEffect) {
        switch effect {
        case .startCapture: startCapture()
        case .finishCapture:
            processingDeadline?.set(clock.now() + machine.config.processingTimeout)
            captureTask?.cancel(); captureTask = nil; feed?.finish(); feed = nil
        case .abortCapture: teardown(); lastResult = nil
        case .loadModel:
            let capture = captureID
            let generation = nextModelLoadGeneration
            nextModelLoadGeneration &+= 1
            let task = Task {
                do {
                    try await self.loadModel()
                    self.modelLoaded(capture: capture, generation: generation)
                } catch {
                    self.modelLoadFailed(error, capture: capture, generation: generation)
                }
            }
            modelLoadTask = (capture, generation, task)
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
            let context = liveContext
            insertionTask = Task {
                guard id == self.captureID, !Task.isCancelled else { return }
                let result: InsertionResult?
                if let context, let live = self.inserter as? any LiveTextInserting {
                    result = await live.finishLiveInsertion(text, cursorOffset: cursorOffset, context: context)
                } else {
                    result = await self.inserter.insert(text, cursorOffset: cursorOffset)
                }
                guard !Task.isCancelled, let result else { return }
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
                let saveID = UUID()
                historySaves[saveID] = Task {
                    await self.onSave(result, appName)
                    self.historySaves[saveID] = nil
                }
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
        let live = captureIsEphemeral ? nil : inserter as? any LiveTextInserting
        if live != nil {
            let validity = CaptureValidity()
            liveValidity = validity
            liveContext = LiveInsertionContext { validity.isActive }
        }
        let context = liveContext
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
        feed = continuation
        let deadline = CaptureDeadline()
        processingDeadline = deadline
        captureTask = Task {
            do {
                for try await event in self.microphone.start() {
                    guard !Task.isCancelled, self.captureID == id else { break }
                    switch event {
                    case .chunk(let chunk): self.receive(chunk, capture: id)
                    case .deviceChanged(let name): self.receiveDeviceChange(name, capture: id)
                    }
                }
            } catch let error as MicrophoneError {
                self.microphoneFailed(error, capture: id)
            } catch {
                self.microphoneFailed(.engineFailed(String(describing: error)), capture: id)
            }
        }
        transcribeTask = Task {
            do {
                if let live, let context { await live.beginLiveInsertion(context) }
                guard id == self.captureID, !Task.isCancelled else { return }
                let result = try await self.transcriber.transcribe(stream, options: self.options(),
                    processingDeadline: { deadline.value }) { event in await self.receive(event, capture: id) }
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
    private func receive(_ event: DictationEvent, capture id: UInt64) async {
        guard id == captureID, !Task.isCancelled else { return }
        switch event {
        case .language(let d): handle(.languageDetected(d))
        case .partialText(let t):
            handle(.partialText(t))
            if let context = liveContext, let live = inserter as? any LiveTextInserting {
                await live.updateLiveInsertion(t, context: context)
            }
        }
    }
    private func receiveDeviceChange(_ name: String?, capture id: UInt64) {
        guard id == captureID else { return }
        for continuation in deviceSubscribers.values { continuation.yield(name) }
        handle(.deviceChanged(name: name))
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

    private func claimModelLoad(capture: UInt64, generation: UInt64) -> Bool {
        guard capture == captureID,
              let active = modelLoadTask,
              active.capture == capture,
              active.generation == generation else { return false }
        modelLoadTask = nil
        return true
    }
    private func modelLoaded(capture: UInt64, generation: UInt64) {
        guard claimModelLoad(capture: capture, generation: generation) else { return }
        handle(.modelLoaded)
    }
    private func modelLoadFailed(_ error: any Error, capture: UInt64, generation: UInt64) {
        guard claimModelLoad(capture: capture, generation: generation) else { return }
        handle(.modelLoadFailed(String(describing: error)))
    }

    private func teardown() {
        let cancelledContext = liveContext
        liveValidity?.cancel(); liveValidity = nil; liveContext = nil
        if let cancelledContext, let live = inserter as? any LiveTextInserting {
            Task { await live.cancelLiveInsertion(cancelledContext) }
        }
        captureID &+= 1   // invalidates every callback still in flight from the old capture
        captureIsEphemeral = false
        processingDeadline = nil
        captureTask?.cancel(); captureTask = nil
        transcribeTask?.cancel(); transcribeTask = nil
        insertionTask?.cancel(); insertionTask = nil
        modelLoadTask?.task.cancel(); modelLoadTask = nil
        feed?.finish(); feed = nil
    }
}

/// Synchronous invalidation lets an AX adapter reject a stale write after an awaited actor hop.
private final class CaptureValidity: Sendable {
    private let active = Mutex(true)
    var isActive: Bool { active.withLock { $0 } }
    func cancel() { active.withLock { $0 = false } }
}

/// One immutable identity per capture; a suspended old transcriber retains only its own deadline.
private final class CaptureDeadline: Sendable {
    private let storage = Mutex<TimeInterval?>(nil)
    var value: TimeInterval? { storage.withLock { $0 } }
    func set(_ value: TimeInterval) { storage.withLock { $0 = value } }
}
