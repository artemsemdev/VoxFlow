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
    /// Not `private` — `ModelStepView` binds `.alert` directly to `models.alert` and calls
    /// `models`' own actions (`openStorageSettings()`, `dismissAlert()`, …), the same way
    /// `ModelsSettingsView` does; reading it inside the view's `body` still participates in that
    /// view's `@Observable` tracking, since `models` is itself `@Observable`.
    let models: ModelsViewModel
    private let dictation: DictationCoordinator
    private let historyWriter: HistoryWriter
    private let navigation: Navigation
    private let clock: any MonotonicClock

    private(set) var step: OnboardingStep
    private(set) var microphone: PermissionState
    private(set) var accessibilityGranted: Bool
    /// ONB-02a: the Accessibility row switches to the amber "not granted" / "Try again" variant only
    /// once the user has had a chance to grant it and a poll still finds it untrusted (M-4) — not the
    /// instant they click "Open System Settings…", which the design frames as "after they came back".
    private(set) var showsAccessibilityDenied = false
    private(set) var selectedModelID = ""
    private(set) var tryItResult: String?
    /// Wall-clock time (`clock.now()`) processing started, captured so `tryItResult`'s elapsed time
    /// survives `DictationCoordinator.elapsed` resetting to 0 by the time `.inserted` arrives.
    private var processingStartedAt: TimeInterval?
    /// Guards the `withObservationTracking` re-registration in `trackDictation()` — armed only by
    /// `beginTryIt()` (the try-it view's `onAppear`) and disarmed by `endTryIt()`, leaving `.tryIt`,
    /// or `finish()`. Without this, a view model that's simply *constructed* while `step == .tryIt`
    /// (every launch, since `AppServices` builds one unconditionally) would suppress history forever.
    private var tryItTrackingEnabled = false

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
        // Never arms try-it tracking (see `tryItTrackingEnabled`) — only step-entry side effects
        // that are safe to repeat on every launch (permissions/model refreshes) run from here.
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
        // Leaving `.tryIt` without ever reaching `.inserted` (e.g. "Back" after only arming) must not
        // leave a stale suppression armed for the next real dictation (M-2).
        if step == .tryIt {
            endTryIt()
            historyWriter.clearSuppression()
        }
        step = newStep
        state.step = newStep
        enter(newStep)
    }

    /// Step-entry side effects — shared by `transition(to:)` and `init` (a relaunch can resume
    /// directly into any step, e.g. `.model`, and needs the same setup as arriving there normally).
    /// Deliberately does **not** touch try-it tracking — see `beginTryIt()`/`endTryIt()`.
    private func enter(_ step: OnboardingStep) {
        switch step {
        case .permissions:
            refreshPermissions()
        case .model:
            Task { await refreshModelStep() }
        default:
            break
        }
    }

    func finish() {
        endTryIt()
        historyWriter.clearSuppression()
        state.completed = true
        state.step = .welcome
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

    /// Sends the user to System Settings; the row stays in its neutral state until the first poll
    /// after that comes back still untrusted (M-4 — the design frames ONB-02a as "after they came
    /// back", not the instant they click through).
    func openAccessibilitySettings() {
        permissions.openAccessibilitySettings()
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

    /// Polls every second (via `clock`, not a real sleep) until either Accessibility is trusted or
    /// the step changes away from `.permissions`. `showsAccessibilityDenied` flips to `true` only
    /// after a poll comes back still untrusted — never on the click that opens System Settings.
    private func startAccessibilityPolling() {
        let task = Task { [weak self] in
            while let self, self.step == .permissions {
                do { try await self.clock.sleep(for: 1) } catch { return }
                guard self.step == .permissions else { return }
                if self.permissions.accessibilityTrusted(prompt: false) {
                    self.accessibilityGranted = true
                    self.showsAccessibilityDenied = false
                    return
                }
                self.showsAccessibilityDenied = true
            }
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
            // The catalog's own recommendation first (M-5) — `Row.isDefault` only reflects which
            // *installed* model dictation currently uses, so on a fresh Mac it's always false and
            // this would otherwise silently fall back to catalog order.
            selectedModelID = models.speechRows.first { $0.model.isDefault }?.id
                ?? models.speechRows.first(where: \.isDefault)?.id
                ?? models.speechRows.first?.id ?? ""
        }
    }

    func useSmallerModel() {
        guard let smaller = smallerModel else { return }
        selectedModelID = smaller.id
    }

    /// ONB-04a's "Use the N model" alert button: drives `models.useSmallerModelInstead()` (which
    /// downloads the fallback) and keeps `selectedModelID` in sync so `modelRow` — and `canContinue`
    /// — reflect the model that's actually installing now, not the one that just failed.
    func useSmallerModelInsufficientSpace() async {
        guard case .insufficientSpace(let failed, _, _) = models.alert else { return }
        let smaller = models.smallerSpeechModel(than: failed)
        await models.useSmallerModelInstead()
        if let smaller { selectedModelID = smaller.id }
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

    /// Arms the try-it observation — called from `TryItStepView.onAppear`. No-ops once onboarding is
    /// `completed` or the step has moved on, so a stray call (or a relaunch that happens to resume on
    /// `.tryIt`) can never suppress history (B-1). Also idempotent while already armed
    /// (`tryItTrackingEnabled`) — SwiftUI can re-run `onAppear` without an intervening `onDisappear`
    /// (observed via `ImageRenderer`, which re-triggers it on every snapshot pass), and re-arming
    /// would otherwise wipe out an in-flight or just-finished capture's `tryItResult` from under it.
    func beginTryIt() {
        guard step == .tryIt, !state.completed, !tryItTrackingEnabled else { return }
        tryItResult = nil
        processingStartedAt = nil
        tryItTrackingEnabled = true
        trackDictation()
    }

    /// Disarms the try-it observation — called from `TryItStepView.onDisappear`, `transition(to:)`
    /// (leaving `.tryIt`), and `finish()`.
    func endTryIt() {
        tryItTrackingEnabled = false
    }

    /// Mirrors `FlowBarPresenter.trackState(of:)`'s `withObservationTracking` pattern, gated by
    /// `tryItTrackingEnabled` (only `beginTryIt()` arms it) rather than just `step == .tryIt`.
    private func trackDictation() {
        withObservationTracking { _ = self.dictation.state } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.tryItTrackingEnabled, self.step == .tryIt else { return }
                self.handleDictationChange()
                self.trackDictation()
            }
        }
    }

    private func handleDictationChange() {
        switch dictation.state {
        case .armed, .tapped, .listening:
            // The Try It capture shouldn't leave a real history entry — `HistoryWriter.save`
            // consumes this flag and skips exactly the one save that follows. Set (idempotently) at
            // every pre-processing state, not just `.armed`, so a fast `.armed → .listening` coalesced
            // by `withObservationTracking` still suppresses (M-3).
            historyWriter.suppressNext()
        case .processing:
            historyWriter.suppressNext()
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
