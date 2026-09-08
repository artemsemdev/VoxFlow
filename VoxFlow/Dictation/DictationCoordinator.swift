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
    private enum Command: Sendable { case fn(FnTransition), escape, anyKey, copyRaw }

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

    func fn(_ t: FnTransition) { commands.yield(.fn(t)) }
    func escape() { commands.yield(.escape) }
    func anyKey() { commands.yield(.anyKey) }
    func copyRaw() { commands.yield(.copyRaw) }

    /// Called from `MeteredMicrophone.onLevel` (wrapped in `Task { @MainActor in }` by the caller).
    func reportLevel(_ rms: Float) {
        levels.removeFirst()
        levels.append(min(1, rms))
    }

    func openSettingsForCurrentError() {
        switch state {
        case .micUnavailable(.denied), .micUnavailable(.noDevice): permissions.openMicrophoneSettings()
        case .error: permissions.openAccessibilitySettings()
        case .modelNotInstalled:
            navigation.settingsTab = .models
            navigation.page = .settings
            navigation.requestMainWindow = true
        default: break
        }
    }
}
