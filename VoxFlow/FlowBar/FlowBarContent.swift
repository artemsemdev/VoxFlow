import Foundation
import VoxFlowCore
import VoxFlowDictation

/// Pure state → copy mapping for the Flow Bar pill (design 1a/2a, FB-01…FB-12). No business rules
/// live in the view — every zone's content and every string come from here, and this is what
/// `FlowBarContentTests` pins down as the copy spec.
struct FlowBarContent: Equatable {
    enum DotColor: Equatable { case idle, recording, warning, error }
    enum Leading: Equatable { case dot(DotColor), spinner, check, cross, excluded }
    enum Button: Equatable { case openSettings, download(sizeText: String), tryAgain, copyRaw }
    enum Trailing: Equatable { case keycap(String), languageChip(String), button(Button) }

    var leading: Leading
    var title: String
    var subtitle: String?
    var showsWaveform: Bool
    var timer: String?
    var timerIsAmber: Bool
    var trailing: Trailing?

    /// `elapsed ≥ 870` (14:30) turns the timer amber — 30 s from the 15-minute cap.
    private static let amberThreshold: TimeInterval = 870
    /// The hard cap on a single dictation (`FlowBarConfig.maxDuration`); "15:00 · limit reached".
    private static let maxDuration: TimeInterval = 900

    static func make(state: FlowBarState, elapsed: TimeInterval, mode: HotkeyMode) -> FlowBarContent {
        switch state {
        case .idle:
            return FlowBarContent(leading: .dot(.idle), title: state.hint(mode: mode) ?? "", subtitle: nil,
                                   showsWaveform: false, timer: nil, timerIsAmber: false, trailing: .keycap("fn"))

        case .loadingModel:
            return FlowBarContent(leading: .spinner, title: "Loading model…", subtitle: "keep talking",
                                   showsWaveform: false, timer: nil, timerIsAmber: false, trailing: nil)

        case .armed, .tapped:
            // Capture is already running; the pill looks like listening minus the timer/chip.
            return FlowBarContent(leading: .dot(.recording), title: "", subtitle: nil,
                                   showsWaveform: true, timer: nil, timerIsAmber: false, trailing: nil)

        case .listening(let listening):
            let amber = elapsed >= amberThreshold
            if listening.mode == .handsFree {
                return FlowBarContent(leading: .dot(.recording), title: "", subtitle: "stop", showsWaveform: true,
                                       timer: timerText(elapsed), timerIsAmber: amber, trailing: .keycap("fn"))
            }
            return FlowBarContent(leading: .dot(.recording), title: "", subtitle: nil, showsWaveform: true,
                                   timer: timerText(elapsed), timerIsAmber: amber,
                                   trailing: .languageChip(languageChipText(listening.language)))

        case .processing(let processing):
            return FlowBarContent(leading: .spinner, title: processing.takingLonger ? "Taking longer…" : "Cleaning up…",
                                   subtitle: "on this Mac", showsWaveform: false, timer: nil, timerIsAmber: false, trailing: nil)

        case .inserted(let appName, let words, let limitReached):
            let title = appName.map { "Inserted into \($0)" } ?? "Inserted"
            let subtitle = limitReached ? "\(timerText(maxDuration)) · limit reached" : "\(words) words"
            return FlowBarContent(leading: .check, title: title, subtitle: subtitle, showsWaveform: false,
                                   timer: nil, timerIsAmber: false, trailing: nil)

        case .copied:
            return FlowBarContent(leading: .check, title: "Copied — no text field here", subtitle: nil,
                                   showsWaveform: false, timer: nil, timerIsAmber: false, trailing: .keycap("⌘V"))

        case .didntCatch(let rawAvailable):
            return FlowBarContent(leading: .dot(.warning), title: "Didn't catch that", subtitle: nil,
                                   showsWaveform: false, timer: nil, timerIsAmber: false,
                                   trailing: .button(rawAvailable ? .copyRaw : .tryAgain))

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

    /// ≥ 1 GB → one decimal ("1.6 GB"); else MB truncated to the nearest ten ("480 MB").
    static func sizeText(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Int(Double(bytes) / 1_000_000)
        return "\((mb / 10) * 10) MB"
    }
}
