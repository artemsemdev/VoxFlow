import Foundation
import VoxFlowCore
import VoxFlowDictation

/// Pure state → copy mapping for the Flow Bar pill (design 1a/2a, FB-01…FB-12). No business rules
/// live in the view — every zone's content and every string come from here, and this is what
/// `FlowBarContentTests` pins down as the copy spec.
struct FlowBarContent: Hashable {
    enum DotColor: Hashable { case idle, recording, warning, error }
    enum Leading: Hashable { case dot(DotColor), spinner, check, cross, excluded }
    enum Button: Hashable { case openSettings, download(sizeText: String), tryAgain, copyRaw, resume }
    enum Trailing: Hashable { case keycap(String), languageChip(String), button(Button) }

    var leading: Leading
    var title: String
    var subtitle: String?
    var showsWaveform: Bool
    var timer: String?
    var timerIsAmber: Bool
    var trailing: Trailing?
    var retryKey = "fn"

    /// Whether `subtitle` rides beside the trailing keycap (FB-02b "fn stop") instead of the title
    /// zone — true exactly when there is no title to attach it to (listening, hands-free). A pure
    /// read of already-decided fields, not a new zone decision — `FlowBarView` reads this instead
    /// of re-deriving `title.isEmpty` itself.
    var subtitleBesideTrailing: Bool { title.isEmpty && subtitle != nil }
    /// Whether the title/subtitle zone renders at all — false while the waveform occupies that
    /// space (listening/armed/tapped) or there is simply no title (shouldn't happen together with
    /// a non-empty title, but keeps the view from having to re-check both conditions itself).
    var showsTitleZone: Bool { !showsWaveform && !title.isEmpty }

    /// Identity for `FlowBarView`'s `.id(...)`-keyed content transition — `self` with the ticking
    /// `timer`/`timerIsAmber` zeroed out. `DictationCoordinator.elapsed` (and so `timer`) changes
    /// every second while listening; keying the transition on the *whole* content would cross-dissolve
    /// the entire pill on every tick instead of just updating the timer text in place.
    var contentIdentity: FlowBarContent {
        var identity = self
        identity.timer = nil
        identity.timerIsAmber = false
        return identity
    }

    static func make(state: FlowBarState, elapsed: TimeInterval, mode: HotkeyMode,
                      config: FlowBarConfig = FlowBarConfig(), now: TimeInterval = 0,
                      shortcuts: DictationShortcuts = DictationShortcuts()) -> FlowBarContent {
        let start = shortcuts[mode == .pushToTalk ? .pushToTalk : .handsFree]
        let startKeys = start.keycaps.joined(separator: " ")
        switch state {
        case .idle:
            let gesture = mode == .pushToTalk ? "Hold" : start.doubleTap ? "Double-tap" : "Press"
            let keyName = start.doubleTap ? "fn" : startKeys
            return FlowBarContent(leading: .dot(.idle), title: "\(gesture) \(keyName) to dictate", subtitle: nil,
                                   showsWaveform: false, timer: nil, timerIsAmber: false, trailing: .keycap(startKeys))

        case .loadingModel:
            return FlowBarContent(leading: .spinner, title: "Loading model…", subtitle: "keep talking",
                                   showsWaveform: false, timer: nil, timerIsAmber: false, trailing: nil)

        case .armed, .tapped:
            // Capture is already running; the pill looks like listening minus the timer/chip.
            return FlowBarContent(leading: .dot(.recording), title: "", subtitle: nil,
                                   showsWaveform: true, timer: nil, timerIsAmber: false, trailing: nil)

        case .listening(let listening):
            // 30 s from the cap (design 2a FB-02b/3d "Auto-dismiss"), read from `FlowBarConfig`
            // rather than a bare literal so a customised `maxDuration` moves the warning with it.
            let amber = elapsed >= config.maxDuration - 30
            if listening.mode == .handsFree {
                let stop = shortcuts[.handsFree]
                // Fn double-tap starts hands-free; a single fn press stops an active session.
                let stopKeys = stop.doubleTap ? "fn" : stop.keycaps.joined(separator: " ")
                return FlowBarContent(leading: .dot(.recording), title: "", subtitle: "stop", showsWaveform: true,
                                       timer: timerText(elapsed), timerIsAmber: amber, trailing: .keycap(stopKeys))
            }
            return FlowBarContent(leading: .dot(.recording), title: "", subtitle: nil, showsWaveform: true,
                                   timer: timerText(elapsed), timerIsAmber: amber,
                                   trailing: .languageChip(languageChipText(listening.language)))

        case .processing(let processing):
            return FlowBarContent(leading: .spinner, title: processing.takingLonger ? "Taking longer…" : "Cleaning up…",
                                   subtitle: "on this Mac", showsWaveform: false, timer: nil, timerIsAmber: false, trailing: nil)

        case .inserted(let appName, let words, let limitReached):
            let title = appName.map { "Inserted into \($0)" } ?? "Inserted"
            let subtitle = limitReached ? "\(timerText(config.maxDuration)) · limit reached" : "\(words) words"
            return FlowBarContent(leading: .check, title: title, subtitle: subtitle, showsWaveform: false,
                                   timer: nil, timerIsAmber: false, trailing: nil)

        case .copied:
            return FlowBarContent(leading: .check, title: "Copied — no text field here", subtitle: nil,
                                   showsWaveform: false, timer: nil, timerIsAmber: false, trailing: .keycap("⌘V"))

        case .didntCatch(let rawAvailable):
            return FlowBarContent(leading: .dot(.warning), title: "Didn't catch that", subtitle: nil,
                                   showsWaveform: false, timer: nil, timerIsAmber: false,
                                   trailing: .button(rawAvailable ? .copyRaw : .tryAgain), retryKey: startKeys)

        case .discarded:
            return FlowBarContent(leading: .cross, title: "Discarded", subtitle: nil, showsWaveform: false,
                                   timer: nil, timerIsAmber: false, trailing: nil)

        case .micUnavailable(let access):
            return FlowBarContent(leading: .dot(.error), title: micTitle(access), subtitle: nil, showsWaveform: false,
                                   timer: nil, timerIsAmber: false, trailing: .button(.openSettings))

        case .modelNotInstalled(let sizeBytes):
            return FlowBarContent(leading: .dot(.warning), title: "Speech model not installed", subtitle: nil,
                                   showsWaveform: false, timer: nil, timerIsAmber: false,
                                   trailing: .button(.download(sizeText: sizeText(sizeBytes))))

        case .excluded(let app):
            return FlowBarContent(leading: .excluded, title: "Dictation is off in \(app)", subtitle: nil,
                                   showsWaveform: false, timer: nil, timerIsAmber: false, trailing: nil)

        case .error(let message):
            return FlowBarContent(leading: .dot(.error), title: message, subtitle: nil, showsWaveform: false,
                                   timer: nil, timerIsAmber: false, trailing: .button(.openSettings))

        case .paused(let until):
            // FB-09 "Paused · 58 min left · Resume". `until` and `now` share the controller's monotonic
            // clock (`DictationCoordinator.now()` in production) — deliberately *not* `elapsed`, which
            // this state doesn't populate (it isn't `.listening`/`.processing`) and would read as 0.
            let minutesLeft = max(0, Int(((until - now) / 60).rounded(.up)))
            return FlowBarContent(leading: .dot(.warning), title: "Paused", subtitle: "\(minutesLeft) min left",
                                   showsWaveform: false, timer: nil, timerIsAmber: false, trailing: .button(.resume))
        }
    }

    private static func micTitle(_ access: MicrophoneAccess) -> String {
        switch access {
        case .denied: "Microphone access needed"
        case .noDevice: "No microphone"
        case .inUse(let app): app.map { "Microphone in use by \($0)" } ?? "Microphone in use by another app"
        case .granted: "Microphone unavailable"
        }
    }

    /// "EN" confident, "EN?" below `LanguageDetection.lowConfidenceThreshold`, "AUTO" before detection.
    private static func languageChipText(_ language: LanguageDetection?) -> String {
        guard let language else { return "AUTO" }
        let code = language.code.uppercased()
        return language.isLowConfidence ? "\(code)?" : code
    }

    static func timerText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// ≥ 1 GB → one decimal ("1.6 GB"); else MB truncated to the nearest ten ("480 MB"). Pinned by
    /// `FlowBarContentTests`, and deliberately *not* `ModelsViewModel.gigabytes` (which rounds to
    /// the nearest MB, "488 MB" for the same bytes) — Settings and the HUD intentionally differ
    /// here; unifying them would mean touching `ModelsViewModel.swift`, outside this task's files.
    static func sizeText(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Int(Double(bytes) / 1_000_000)
        return "\((mb / 10) * 10) MB"
    }
}
