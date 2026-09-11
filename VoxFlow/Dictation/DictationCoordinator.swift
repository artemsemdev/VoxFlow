import Foundation
import Synchronization
import VoxFlowCore
import VoxFlowDictation

/// Main-actor mirror of `DictationController` for the HUD (FB-01…FB-12) — state, waveform levels, elapsed time.
@Observable @MainActor
final class DictationCoordinator {
    static let barCount = 14
    private let controller: DictationController
    private let settings: DictationSettings
    private let permissions: any PermissionChecking
    private let navigation: Navigation
    /// The coordinator's own "now" (`now()`, below) — ideally the same instance the controller's
    /// clock uses (production wiring lives in `AppServices.swift`, outside this task's file scope),
    /// so `pausedUntil`'s monotonic timeline projects onto a wall-clock `Date` consistently
    /// wherever a reader (e.g. `MenuBarViewModel.pausedUntilText`) does that math. Defaulted so
    /// every existing call site keeps compiling unchanged.
    private let clock: any MonotonicClock
    /// Boxed outside main-actor isolation so `deinit` (nonisolated, may run on any thread) can cancel
    /// it without an isolation assertion — same pattern as `FilesViewModel.eventTask`.
    private nonisolated let mirror = Mutex<Task<Void, Never>?>(nil)
    private let commands = DictationCommandQueue()
    private var ticker: Task<Void, Never>?
    /// True from the moment a `.notDetermined` fn-down triggers the Microphone request until it
    /// resolves — while true, `fn(_:)` neither enqueues the down (avoids `preflight()` suspending
    /// on the OS dialog inside the command queue, see I-1) nor the matching up (which belongs to
    /// the prompt, not a dictation, and must not be replayed against the very next armed state).
    private(set) var isRequestingMicrophoneAccess = false
    private var pendingActivation: (id: UUID, mode: HotkeyMode?)?
    private var pendingReinsertion: UUID?

    private(set) var state: FlowBarState = .idle
    private(set) var levels: [Float] = Array(repeating: 0, count: DictationCoordinator.barCount)
    private(set) var elapsed: TimeInterval = 0
    var hotkeyMode: HotkeyMode { settings.hotkeyMode }
    var shortcuts: DictationShortcuts { settings.shortcuts }
    /// I1: `.paused` is excluded even though `state != .idle` — before FB-09 every non-idle state
    /// was seconds long, but `.paused(until:)` lasts up to an hour, and `FnKeyMonitor` gates its
    /// *global* `.keyDown` handler on this. Leaving `.paused` "HUD active" meant every keystroke in
    /// every app, for the whole pause, forwarded an `anyKey()`/`escape()` command into the
    /// coordinator for no visible effect (`FlowBarMachine` already ignores them from `.paused` —
    /// see `default: return []`) — harmless, but a needless firehose into the dictation actor and a
    /// hijacked Esc key system-wide. The paused pill itself is unaffected: `FlowBarPresenter` shows/
    /// hides off `state`, never off this property.
    var isHUDActive: Bool { state != .idle && pausedUntil == nil }
    var shortcutContext: ShortcutContext {
        ShortcutContext(hudActive: isHUDActive || pendingActivation != nil || pendingReinsertion != nil,
                        handsFree: activeMode == .handsFree || pendingActivation?.mode == .handsFree)
    }
    private var activeMode: HotkeyMode? {
        switch state {
        case .armed(let pending), .loadingModel(let pending): pending.resolvedMode
        case .listening(let listening): listening.mode
        default: nil
        }
    }
    func shortcutDown(_ mode: HotkeyMode) { activate(mode: mode) }
    func pushToTalkReleased() { commands.send { [controller] in await controller.pushToTalkReleased() } }
    func reinsertLast(using support: ReinsertionSupport) {
        guard pausedUntil == nil, pendingReinsertion == nil else { return }
        let id = UUID()
        pendingReinsertion = id
        commands.send(preparation: true) { [weak self, controller] in
            await controller.reinsertLast(prepare: { await support.prepareTarget() },
                                          lastSaved: { await support.lastSaved() })
            await self?.finishReinsertion(id)
        }
    }

    private func finishReinsertion(_ id: UUID) {
        if pendingReinsertion == id { pendingReinsertion = nil }
    }

    init(controller: DictationController, settings: DictationSettings, permissions: any PermissionChecking, navigation: Navigation,
         clock: any MonotonicClock = SystemMonotonicClock()) {
        self.controller = controller
        self.settings = settings
        self.permissions = permissions
        self.navigation = navigation
        self.clock = clock
    }

    /// Begins mirroring `controller.currentAndChanges()` and starts the command consumer — separate
    /// from `init` so both only start once the coordinator is fully constructed.
    func start() {
        let mirrorTask = Task { [weak self, controller] in
            for await s in await controller.currentAndChanges() {
                guard let self else { return }
                self.apply(s)
            }
        }
        mirror.withLock { $0?.cancel(); $0 = mirrorTask }

        commands.start()
    }

    deinit {
        mirror.withLock { $0?.cancel() }
    }

    private func apply(_ s: FlowBarState) {
        state = s
        switch s {
        case .listening, .processing: startTicker()
        default:
            stopTicker()
            elapsed = 0
            if case .idle = s { levels = Array(repeating: 0, count: Self.barCount) }
        }
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self, controller] in
            while !Task.isCancelled {
                let e = await controller.elapsed ?? 0
                guard let self else { return }
                self.elapsed = e
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
    private func stopTicker() { ticker?.cancel(); ticker = nil }

    /// I-1: a `.notDetermined` fn-down is diverted here instead of reaching the command queue, whose
    /// single consumer would otherwise suspend inside `DictationController.fnDown()`'s `preflight()`
    /// for as long as the human takes to answer the TCC dialog — during which a released fn queues up
    /// behind it and replays the instant the dialog resolves, ending a dictation that never started
    /// (the owner's very first manual e2e). The prompt runs outside the queue instead, and the fn-up
    /// that belongs to it is swallowed rather than forwarded.
    func fn(_ t: FnTransition) {
        if case .down = t { activate(mode: nil); return }
        guard !isRequestingMicrophoneAccess else { return }
        commands.send { [controller] in await controller.fnUp() }
    }

    private func activate(mode: HotkeyMode?) {
        guard pausedUntil == nil else { return }
        if !isRequestingMicrophoneAccess, permissions.microphone() == .notDetermined {
            isRequestingMicrophoneAccess = true
            Task { @MainActor [weak self, permissions] in
                _ = await permissions.requestMicrophone()
                self?.isRequestingMicrophoneAccess = false
            }
            return
        }
        guard !isRequestingMicrophoneAccess else { return }
        let id = UUID()
        pendingActivation = (id, mode)
        commands.send(preparation: true) { [weak self, controller] in
            if let mode { await controller.shortcutDown(mode) }
            else { await controller.fnDown() }
            await self?.finishActivation(id)
        }
    }

    private func finishActivation(_ id: UUID) {
        guard pendingActivation?.id == id else { return }
        pendingActivation = nil
    }
    /// The MCP `dictate` seam starts the controller's dedicated hands-free action through the same
    /// cancellable queue and microphone-permission gate as a shortcut. It deliberately does not
    /// synthesize legacy fn transitions, whose tap timing is unrelated to a programmatic request.
    func startProgrammaticDictation() {
        activate(mode: .handsFree)
    }

    func escape() {
        pendingActivation = nil
        pendingReinsertion = nil
        commands.cancelPreparations()
        commands.send { [controller] in await controller.escape() }
    }
    func anyKey() { commands.send { [controller] in await controller.anyKey() } }
    func copyRaw() { commands.send { [controller] in await controller.copyRaw() } }
    /// FB-09: menu bar / Flow Bar pill "Pause dictation for 1 hour" and "Resume".
    func pause(for seconds: TimeInterval) { commands.send { [controller] in await controller.pause(for: seconds) } }
    func resume() { commands.send { [controller] in await controller.resume() } }
    /// Mirrors `state` — `nil` outside `.paused`. Monotonic (the controller's clock), like
    /// `DictationController.pausedUntil`; converting to a wall-clock "until 10:41" is the menu
    /// bar/pill's job (Task 4), not this coordinator's.
    var pausedUntil: TimeInterval? {
        if case .paused(let until) = state { until } else { nil }
    }

    /// This coordinator's own monotonic "now" (`clock.now()`) — what `FlowBarView` passes as
    /// `FlowBarContent.make(now:)` for the `.paused` pill's "N min left" countdown (Task 4). Not
    /// `@Observable` state: a plain function call, read only when SwiftUI re-renders for some other
    /// reason (see review M4 at `FlowBarView.content`'s `.coordinator` case) — the countdown is a
    /// snapshot at render time, not a live ticker.
    func now() -> TimeInterval { clock.now() }

    /// Called from `MeteredMicrophone.onLevel` (wrapped in `Task { @MainActor in }` by the caller).
    func reportLevel(_ rms: Float) {
        levels.removeFirst()
        levels.append(min(1, rms))
    }

    func openSettingsForCurrentError() {
        switch state {
        case .micUnavailable(.denied), .micUnavailable(.noDevice): permissions.openMicrophoneSettings()
        case .error, .modelNotInstalled:
            // `.error` (model-load / transcription failure) has nothing to do with Accessibility —
            // Settings › Models is where it can actually help (I-2). `openAccessibilitySettings()` is
            // reserved for a future Accessibility-denied state (see the Accessibility-denied follow-up issue).
            navigation.settingsTab = .models
            navigation.page = .settings
            navigation.requestMainWindow = true
        default: break
        }
    }
}
