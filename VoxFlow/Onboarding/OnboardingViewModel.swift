import Foundation
import Synchronization
import VoxFlowCore
import VoxFlowDictation
import VoxFlowModels

/// Drives ONB-01…05 (design), including the ONB-02a Accessibility-denied branch and the ONB-04
/// model download. One instance lives for the whole flow (`AppServices`), stepping forward/back
/// through `OnboardingStep` and persisting progress into `state`.
@Observable @MainActor
final class OnboardingViewModel {
    private let state: OnboardingState
    private let permissions: any PermissionChecking
    private let settings: DictationSettings
    private let models: ModelsViewModel
    private let dictation: DictationCoordinator
    private let historyWriter: HistoryWriter
    private let navigation: Navigation
    private let clock: any MonotonicClock

    private(set) var step: OnboardingStep
    private(set) var microphone: PermissionState
    private(set) var accessibilityGranted: Bool
    /// ONB-02a: the Accessibility row switches to the amber "not granted" / "Try again" variant once
    /// the user has been sent to System Settings at least once and it's still not trusted.
    private(set) var showsAccessibilityDenied = false
    private(set) var selectedModelID = ""
    private(set) var tryItResult: String?
    /// Wall-clock time (`clock.now()`) processing started, captured so `tryItResult`'s elapsed time
    /// survives `DictationCoordinator.elapsed` resetting to 0 by the time `.inserted` arrives.
    private var processingStartedAt: TimeInterval?

    /// Set by the view (`OnboardingWindow`, from `@Environment(\.dismissWindow)`) — `finish()` calls
    /// it to close the onboarding window. A plain closure (not the environment action itself) keeps
    /// this view model SwiftUI-independent, same reasoning as `DictationCoordinator`'s callbacks.
    var dismiss: () -> Void = {}

    /// Cancelled on every step change and on deinit — boxed outside main-actor isolation the same
    /// way `DictationCoordinator.mirror` is, so `deinit` (nonisolated) can cancel it safely.
    private nonisolated let accessibilityPollTask = Mutex<Task<Void, Never>?>(nil)

    init(state: OnboardingState, permissions: any PermissionChecking, settings: DictationSettings,
         models: ModelsViewModel, dictation: DictationCoordinator, historyWriter: HistoryWriter,
         navigation: Navigation, clock: any MonotonicClock) {
        self.state = state
        self.permissions = permissions
        self.settings = settings
        self.models = models
        self.dictation = dictation
        self.historyWriter = historyWriter
        self.navigation = navigation
        self.clock = clock
        self.step = state.step
        self.microphone = permissions.microphone()
        self.accessibilityGranted = permissions.accessibilityTrusted(prompt: false)
        enter(step)
    }

    deinit {
        accessibilityPollTask.withLock { $0?.cancel() }
    }

    // MARK: Navigation

    var canContinue: Bool {
        switch step {
        case .welcome, .hotkey, .tryIt: true
        case .permissions: microphone == .granted && (accessibilityGranted || state.accessibilitySkipped)
        case .model: modelRow?.state == .installed
        }
    }

    func next() {
        guard let nextStep = OnboardingStep(rawValue: step.rawValue + 1) else { return }
        transition(to: nextStep)
    }

    func back() {
        guard let previousStep = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        transition(to: previousStep)
    }

    private func transition(to newStep: OnboardingStep) {
        accessibilityPollTask.withLock { $0?.cancel() }
        step = newStep
        state.step = newStep
        enter(newStep)
    }

    /// Step-entry side effects — shared by `transition(to:)` and `init` (a relaunch can resume
    /// directly into any step, e.g. `.model`, and needs the same setup as arriving there normally).
    private func enter(_ step: OnboardingStep) {
        switch step {
        case .permissions:
            refreshPermissions()
        case .model:
            Task { await refreshModelStep() }
        case .tryIt:
            tryItResult = nil
            processingStartedAt = nil
            trackDictation()
        default:
            break
        }
    }

    func finish() {
        state.completed = true
        navigation.requestMainWindow = true
        dismiss()
    }

    // MARK: Permissions (ONB-02 / ONB-02a)

    private func refreshPermissions() {
        microphone = permissions.microphone()
        accessibilityGranted = permissions.accessibilityTrusted(prompt: false)
        if accessibilityGranted { showsAccessibilityDenied = false }
    }

    func requestMicrophone() async {
        microphone = await permissions.requestMicrophone()
    }

    /// Sends the user to System Settings and polls every second (via `clock`, not a real sleep)
    /// until either Accessibility is trusted or the step changes away from `.permissions`.
    func openAccessibilitySettings() {
        permissions.openAccessibilitySettings()
        showsAccessibilityDenied = true
        startAccessibilityPolling()
    }

    func tryAgainAccessibility() {
        accessibilityGranted = permissions.accessibilityTrusted(prompt: false)
        if accessibilityGranted {
            showsAccessibilityDenied = false
        } else {
            showsAccessibilityDenied = true
            permissions.openAccessibilitySettings()
            startAccessibilityPolling()
        }
    }

    func continueWithClipboard() {
        state.accessibilitySkipped = true
        next()
    }

    private func startAccessibilityPolling() {
        let task = Task { [weak self] in
            while let self, self.step == .permissions, !self.permissions.accessibilityTrusted(prompt: false) {
                do { try await self.clock.sleep(for: 1) } catch { return }
            }
            guard let self, self.step == .permissions, self.permissions.accessibilityTrusted(prompt: false) else { return }
            self.accessibilityGranted = true
            self.showsAccessibilityDenied = false
        }
        accessibilityPollTask.withLock { $0?.cancel(); $0 = task }
    }

    // MARK: Hotkey (ONB-03)

    var hotkeyMode: HotkeyMode { settings.hotkeyMode }
    func choose(_ mode: HotkeyMode) { settings.hotkeyMode = mode }

    // MARK: Model (ONB-04)

    var modelRow: ModelsViewModel.Row? { models.speechRows.first { $0.id == selectedModelID } }
    var smallerModel: ModelDescriptor? {
        guard let model = modelRow?.model else { return nil }
        return models.smallerSpeechModel(than: model)
    }
    func downloadText(for row: ModelsViewModel.Row) -> String { models.downloadText(for: row) }

    private func refreshModelStep() async {
        await models.refresh()
        if selectedModelID.isEmpty || modelRow == nil {
            selectedModelID = models.speechRows.first(where: \.isDefault)?.id ?? models.speechRows.first?.id ?? ""
        }
    }

    func useSmallerModel() {
        guard let smaller = smallerModel else { return }
        selectedModelID = smaller.id
    }

    func download() async {
        guard let model = modelRow?.model else { return }
        await models.download(model)
        if modelRow?.state == .installed { next() }
    }

    func pause() async {
        guard let model = modelRow?.model else { return }
        await models.pause(model)
    }

    // MARK: Try it (ONB-05)

    /// Mirrors `FlowBarPresenter.trackState(of:)`'s `withObservationTracking` pattern, but only
    /// re-registers while still on `.tryIt` — leaving the step (or `deinit`) lets the chain lapse.
    private func trackDictation() {
        withObservationTracking { _ = self.dictation.state } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.step == .tryIt else { return }
                self.handleDictationChange()
                self.trackDictation()
            }
        }
    }

    private func handleDictationChange() {
        switch dictation.state {
        case .armed:
            // The Try It capture shouldn't leave a real history entry — `HistoryWriter.save`
            // consumes this flag and skips exactly the one save that follows.
            historyWriter.suppressNext()
        case .processing:
            processingStartedAt = clock.now()
        case .inserted(_, let words, _):
            let elapsed = processingStartedAt.map { clock.now() - $0 } ?? dictation.elapsed
            tryItResult = "✓ Inserted · \(words) words · \(String(format: "%.1f", elapsed)) s"
            processingStartedAt = nil
        default:
            break
        }
    }
}
