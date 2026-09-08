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
    /// Boxed outside main-actor isolation so `deinit` (nonisolated, may run on any thread) can cancel
    /// it without an isolation assertion — same pattern as `FilesViewModel.eventTask`.
    private let mirror = Mutex<Task<Void, Never>?>(nil)
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
    }

    /// Begins mirroring `controller.currentAndChanges()` — separate from `init` so the stream (and
    /// its immediately-yielded current state) only starts once the coordinator is fully constructed.
    func start() {
        let task = Task { [weak self, controller] in
            for await s in await controller.currentAndChanges() {
                guard let self else { return }
                self.apply(s)
            }
        }
        mirror.withLock { $0?.cancel(); $0 = task }
    }

    deinit { mirror.withLock { $0?.cancel() } }

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

    func fn(_ t: FnTransition) {
        Task { [controller] in switch t { case .down: await controller.fnDown(); case .up: await controller.fnUp() } }
    }
    func escape() { Task { [controller] in await controller.escape() } }
    func anyKey() { Task { [controller] in await controller.anyKey() } }
    func copyRaw() { Task { [controller] in await controller.copyRaw() } }

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
