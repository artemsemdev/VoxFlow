import Foundation
import Synchronization
import VoxFlowCore
import VoxFlowDictation

/// Main-actor mirror of `DictationController` for the HUD (FB-01…FB-12) — state, waveform levels, elapsed time.
@Observable @MainActor
final class DictationCoordinator {
    /// One command per public "send this to the controller" method. Routed through a single-consumer
    /// channel (see `commands`/`commandStream`) so `fn`/`escape`/`anyKey`/`copyRaw` reach the actor in
    /// the order they were called, even though `DictationController.fnDown()` suspends internally on
    /// `preflight()` — four independent `Task { await controller… }` call sites would let the actor
    /// reorder them (e.g. a quick tap's `fnUp` overtaking a still-suspended `fnDown`).
    private enum Command: Sendable { case fn(FnTransition), escape, anyKey, copyRaw, pause(seconds: TimeInterval), resume }

    static let barCount = 14
    private let controller: DictationController
    private let settings: DictationSettings
    private let permissions: any PermissionChecking
    private let navigation: Navigation
    /// Boxed outside main-actor isolation so `deinit` (nonisolated, may run on any thread) can cancel
    /// it without an isolation assertion — same pattern as `FilesViewModel.eventTask`.
    private nonisolated let mirror = Mutex<Task<Void, Never>?>(nil)
    /// Same reasoning as `mirror`, for the command-consumer task started in `start()`.
    private nonisolated let commandsTask = Mutex<Task<Void, Never>?>(nil)
    private let commands: AsyncStream<Command>.Continuation
    private let commandStream: AsyncStream<Command>
    private var ticker: Task<Void, Never>?
    /// True from the moment a `.notDetermined` fn-down triggers the Microphone request until it
    /// resolves — while true, `fn(_:)` neither enqueues the down (avoids `preflight()` suspending
    /// on the OS dialog inside the command queue, see I-1) nor the matching up (which belongs to
    /// the prompt, not a dictation, and must not be replayed against the very next armed state).
    private var isRequestingMicrophoneAccess = false

    private(set) var state: FlowBarState = .idle
    private(set) var levels: [Float] = Array(repeating: 0, count: DictationCoordinator.barCount)
    private(set) var elapsed: TimeInterval = 0
    var hotkeyMode: HotkeyMode { settings.hotkeyMode }
    var isHUDActive: Bool { state != .idle }

    init(controller: DictationController, settings: DictationSettings, permissions: any PermissionChecking, navigation: Navigation) {
        self.controller = controller
        self.settings = settings
        self.permissions = permissions
        self.navigation = navigation
        (commandStream, commands) = AsyncStream<Command>.makeStream()
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

        // No `[weak self]` needed: this loop never touches `self`, only `controller` and the stream.
        let commandTask = Task { [controller, commandStream] in
            for await cmd in commandStream {
                switch cmd {
                case .fn(.down): await controller.fnDown()
                case .fn(.up): await controller.fnUp()
                case .escape: await controller.escape()
                case .anyKey: await controller.anyKey()
                case .copyRaw: await controller.copyRaw()
                case .pause(let seconds): await controller.pause(for: seconds)
                case .resume: await controller.resume()
                }
            }
        }
        commandsTask.withLock { $0?.cancel(); $0 = commandTask }
    }

    deinit {
        mirror.withLock { $0?.cancel() }
        commandsTask.withLock { $0?.cancel() }
        commands.finish()
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
        if case .down = t, !isRequestingMicrophoneAccess, permissions.microphone() == .notDetermined {
            isRequestingMicrophoneAccess = true
            Task { @MainActor [weak self, permissions] in
                _ = await permissions.requestMicrophone()
                self?.isRequestingMicrophoneAccess = false
            }
            return
        }
        guard !isRequestingMicrophoneAccess else { return }
        commands.yield(.fn(t))
    }
    func escape() { commands.yield(.escape) }
    func anyKey() { commands.yield(.anyKey) }
    func copyRaw() { commands.yield(.copyRaw) }
    /// FB-09: menu bar / Flow Bar pill "Pause dictation for 1 hour" and "Resume".
    func pause(for seconds: TimeInterval) { commands.yield(.pause(seconds: seconds)) }
    func resume() { commands.yield(.resume) }
    /// Mirrors `state` — `nil` outside `.paused`. Monotonic (the controller's clock), like
    /// `DictationController.pausedUntil`; converting to a wall-clock "until 10:41" is the menu
    /// bar/pill's job (Task 4), not this coordinator's.
    var pausedUntil: TimeInterval? {
        if case .paused(let until) = state { until } else { nil }
    }

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
