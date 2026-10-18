import Foundation
import VoxFlowCore

public enum MicrophoneAccess: Sendable, Equatable {
    case granted, denied, noDevice
    case inUse(by: String?)
}

public enum ModelReadiness: Sendable, Equatable {
    case loaded, installedNotLoaded
    case notInstalled(sizeBytes: Int64)
}

/// What the app knows at the moment fn goes down (phase 3b gathers it; tests build it directly).
public struct Preflight: Sendable, Equatable {
    public var excludedApp: String?
    public var secureInput: Bool
    public var microphone: MicrophoneAccess
    public var model: ModelReadiness
    public init(excludedApp: String?, secureInput: Bool, microphone: MicrophoneAccess, model: ModelReadiness) {
        self.excludedApp = excludedApp
        self.secureInput = secureInput
        self.microphone = microphone
        self.model = model
    }
}

public enum FlowBarTimer: Sendable, Hashable { case hold, doubleTap, silence, cap, takingLonger, processingTimeout, dismiss, modelLoad, pauseEnd }

public enum FlowBarEvent: Sendable, Equatable {
    /// A continuation/stop may omit preflight; starting capture always requires fresh checks.
    case fnDown(Preflight?), fnUp, escape, anyKey
    case finishRequested
    /// A separately assigned shortcut has no ambiguous hold/double-tap gesture to resolve.
    /// Missing preflight permits stopping only; it can never start a capture.
    case shortcutDown(HotkeyMode, Preflight?), pushToTalkReleased
    case level(rms: Float)
    case timer(FlowBarTimer)
    case modelLoaded, modelLoadFailed(String)
    case languageDetected(LanguageDetection)
    case partialText(String)
    case transcriptReady(text: String, lowConfidence: Bool)
    case transcriptionFailed(String)
    case microphoneFailed(MicrophoneError)
    /// A named replacement keeps the capture alive; nil means no input device remains.
    case deviceChanged(name: String?)
    case insertionFinished(InsertionResult)
    case copyRawRequested
    case reinsertionFinished(text: String, result: InsertionResult), reinsertionBlocked(String)
    /// FB-09: "Pause dictation for 1 hour" from the menu bar or the Flow Bar pill.
    case pause(seconds: TimeInterval)
    case resume
}

public enum FlowBarEffect: Sendable, Equatable {
    case startCapture          // open the mic and start the windowed transcriber on its feed
    case finishCapture         // stop the mic, let the transcriber flush → `.transcriptReady`
    case abortCapture          // stop the mic and cancel the transcriber; no result
    case loadModel             // → `.modelLoaded` / `.modelLoadFailed`
    case startTimer(FlowBarTimer, seconds: TimeInterval)
    case cancelTimer(FlowBarTimer)
    case insert(String)        // → `.insertionFinished`
    case copyToClipboard(String)
    case saveHistory           // controller persists the last `DictationResult`
}

public struct Pending: Sendable, Equatable {
    public var downAt: TimeInterval
    public var fnIsDown: Bool
    public var resolvedMode: HotkeyMode?
    /// A dedicated hands-free key can request stop before the model finishes loading.
    public var stopRequested = false
    public init(downAt: TimeInterval, fnIsDown: Bool, resolvedMode: HotkeyMode?) {
        self.downAt = downAt
        self.fnIsDown = fnIsDown
        self.resolvedMode = resolvedMode
    }
}

public struct Listening: Sendable, Equatable {
    public var mode: HotkeyMode
    public var startedAt: TimeInterval
    public var language: LanguageDetection?
    public init(mode: HotkeyMode, startedAt: TimeInterval, language: LanguageDetection?) {
        self.mode = mode
        self.startedAt = startedAt
        self.language = language
    }
}

public struct Processing: Sendable, Equatable {
    public var startedAt: TimeInterval
    public var takingLonger: Bool
    public var limitReached: Bool
    public var partialText: String
    public init(startedAt: TimeInterval, takingLonger: Bool, limitReached: Bool, partialText: String) {
        self.startedAt = startedAt
        self.takingLonger = takingLonger
        self.limitReached = limitReached
        self.partialText = partialText
    }
}

public enum FlowBarState: Sendable, Equatable {
    case idle
    case loadingModel(Pending)
    case armed(Pending)
    case tapped(Pending)
    case listening(Listening)
    case processing(Processing)
    case inserted(appName: String?, words: Int, limitReached: Bool)
    case copied(CopyReason)
    case didntCatch(rawAvailable: Bool)
    case discarded
    case micUnavailable(MicrophoneAccess)
    case modelNotInstalled(sizeBytes: Int64)
    case excluded(app: String)
    case error(String)
    /// FB-09: dictation paused (menu bar / Flow Bar pill) until this monotonic time. Reachable from
    /// `.idle` or any dismissable state; not itself dismissable — fn-down while paused is ignored
    /// rather than treated as a retry (only `.resume` or the `.pauseEnd` timer clears it).
    case paused(until: TimeInterval)

    public var hasUnfinishedCapture: Bool {
        switch self {
        case .armed, .tapped, .loadingModel, .listening, .processing: true
        default: false
        }
    }

    public var isProcessing: Bool { if case .processing = self { true } else { false } }

    /// States that auto-dismiss and treat fn-down as a retry.
    public var isDismissable: Bool {
        switch self {
        case .inserted, .copied, .didntCatch, .discarded, .micUnavailable, .modelNotInstalled, .excluded, .error: true
        default: false
        }
    }

    /// Hint text under the pill (FB-01 idle hint follows the default mode; FB-02b shows "fn — stop").
    public func hint(mode: HotkeyMode) -> String? {
        switch self {
        case .idle: mode == .pushToTalk ? "Hold fn to dictate" : "Press fn to dictate"
        case .listening(let l): l.mode == .handsFree ? "fn — stop" : nil
        default: nil
        }
    }
}

/// Pure reducer for the Flow Bar. `handle` returns the effects the driver must run, in order.
public struct FlowBarMachine: Sendable, Equatable {
    public var state: FlowBarState = .idle
    public var config: FlowBarConfig
    /// Text recognized so far in the current dictation (for FB-03 partials and "Copy raw transcript").
    public private(set) var partialText = ""
    private var lastTranscript = ""

    public init(config: FlowBarConfig = FlowBarConfig()) { self.config = config }

    public static func wordCount(_ text: String) -> Int { text.wordCount }

    public mutating func handle(_ event: FlowBarEvent, now: TimeInterval) -> [FlowBarEffect] {
        switch (state, event) {
        case (.armed, .finishRequested), (.tapped, .finishRequested), (.listening, .finishRequested):
            return startProcessing(now: now, limitReached: false, cancelling: [.hold, .doubleTap, .cap, .silence])
        case (.loadingModel(var pending), .finishRequested):
            pending.stopRequested = true
            state = .loadingModel(pending)
            return [.cancelTimer(.hold), .cancelTimer(.doubleTap)]
        case (let s, .reinsertionFinished(let text, let result)) where s == .idle || s.isDismissable:
            switch result {
            case .inserted(let app):
                state = .inserted(appName: app, words: Self.wordCount(text), limitReached: false)
                return [.cancelTimer(.dismiss), .startTimer(.dismiss, seconds: config.dismissInserted)]
            case .copiedToClipboard(let reason):
                state = .copied(reason)
                return [.cancelTimer(.dismiss), .startTimer(.dismiss, seconds: reason == .accessibilityDenied ? config.dismissError : config.dismissCopied)]
            }
        case (let s, .reinsertionBlocked(let app)) where s == .idle || s.isDismissable:
            state = .excluded(app: app)
            return [.cancelTimer(.dismiss), .startTimer(.dismiss, seconds: config.dismissError)]
        case (.idle, .shortcutDown(let mode, let p?)):
            return begin(p, now: now, cancelDismiss: false, mode: mode)
        case (let s, .shortcutDown(let mode, let p?)) where s.isDismissable:
            return begin(p, now: now, cancelDismiss: true, mode: mode)
        case (.listening(let l), .shortcutDown(.handsFree, _)) where l.mode == .handsFree:
            return startProcessing(now: now, limitReached: false, cancelling: [.cap, .silence])
        case (.listening(let l), .pushToTalkReleased) where l.mode == .pushToTalk:
            return startProcessing(now: now, limitReached: false, cancelling: [.cap, .silence])
        case (.loadingModel(var p), .pushToTalkReleased) where p.resolvedMode == .pushToTalk:
            p.fnIsDown = false
            state = .loadingModel(p)
            return []
        case (.loadingModel(var p), .shortcutDown(.handsFree, _)) where p.resolvedMode == .handsFree:
            p.stopRequested = true
            state = .loadingModel(p)
            return []

        // ── fn-down: from idle or any dismissable state ──
        case (.idle, .fnDown(let p?)):
            return begin(p, now: now, cancelDismiss: false)
        case (let s, .fnDown(let p?)) where s.isDismissable:
            return begin(p, now: now, cancelDismiss: true)
        case (let s, .anyKey) where s.isDismissable:
            state = .idle
            return [.cancelTimer(.dismiss)]
        case (let s, .timer(.dismiss)) where s.isDismissable:
            state = .idle
            return []

        // ── FB-09 pause: from idle or any dismissable state; ignored mid-dictation ──
        case (.idle, .pause(let seconds)):
            state = .paused(until: now + seconds)
            return [.startTimer(.pauseEnd, seconds: seconds)]
        case (let s, .pause(let seconds)) where s.isDismissable:
            state = .paused(until: now + seconds)
            return [.cancelTimer(.dismiss), .startTimer(.pauseEnd, seconds: seconds)]
        case (.paused, .resume):
            state = .idle
            return [.cancelTimer(.pauseEnd)]
        case (.paused, .timer(.pauseEnd)):
            state = .idle
            return []

        // ── armed / loading: deciding between hold and tap ──
        case (.armed(var p), .timer(.hold)) where p.resolvedMode == nil:
            p.resolvedMode = .pushToTalk
            state = .listening(Listening(mode: .pushToTalk, startedAt: p.downAt, language: nil))
            return [.startTimer(.cap, seconds: config.maxDuration)]
        case (.loadingModel(var p), .timer(.hold)) where p.resolvedMode == nil:
            p.resolvedMode = .pushToTalk
            state = .loadingModel(p)
            return []
        case (.armed(var p), .fnUp) where p.resolvedMode == nil:
            p.fnIsDown = false
            state = .tapped(p)
            return [.cancelTimer(.hold), .startTimer(.doubleTap, seconds: config.doubleTapWindow)]
        case (.loadingModel(var p), .fnUp) where p.resolvedMode == nil:
            p.fnIsDown = false
            state = .loadingModel(p)
            return [.cancelTimer(.hold), .startTimer(.doubleTap, seconds: config.doubleTapWindow)]
        case (.loadingModel(var p), .fnUp):          // hold already resolved, released before the model is ready
            p.fnIsDown = false
            state = .loadingModel(p)
            return []
        case (.tapped(var p), .fnDown):
            p.fnIsDown = true
            p.resolvedMode = .handsFree
            state = .listening(Listening(mode: .handsFree, startedAt: p.downAt, language: nil))
            return [.cancelTimer(.doubleTap), .startTimer(.cap, seconds: config.maxDuration),
                    .startTimer(.silence, seconds: config.silenceStop)]
        case (.loadingModel(var p), .fnDown) where p.resolvedMode == nil && !p.fnIsDown:
            p.fnIsDown = true
            p.resolvedMode = .handsFree
            state = .loadingModel(p)
            return [.cancelTimer(.doubleTap)]
        case (.tapped, .timer(.doubleTap)):
            state = .idle
            return [.abortCapture]
        case (.loadingModel(let p), .timer(.doubleTap)) where p.resolvedMode == nil:
            state = .idle
            return [.abortCapture]
        case (.loadingModel(let p), .modelLoaded):
            if p.stopRequested {
                return [.cancelTimer(.modelLoad)] + startProcessing(now: now, limitReached: false, cancelling: [])
            }
            switch p.resolvedMode {
            case .pushToTalk where p.fnIsDown:
                state = .listening(Listening(mode: .pushToTalk, startedAt: p.downAt, language: nil))
                return [.cancelTimer(.modelLoad), .startTimer(.cap, seconds: config.maxDuration)]
            case .pushToTalk:                          // released while loading → straight to processing
                return [.cancelTimer(.modelLoad)] + startProcessing(now: now, limitReached: false, cancelling: [])
            case .handsFree:
                state = .listening(Listening(mode: .handsFree, startedAt: p.downAt, language: nil))
                return [.cancelTimer(.modelLoad), .startTimer(.cap, seconds: config.maxDuration), .startTimer(.silence, seconds: config.silenceStop)]
            case nil:
                state = .armed(p)
                return [.cancelTimer(.modelLoad)]
            }
        case (.loadingModel, .modelLoadFailed), (.loadingModel, .timer(.modelLoad)):
            // A stalled load times out the same way a reported failure does: the mic must not stay
            // open indefinitely with no way for the user to escape (I1).
            state = .error("Couldn't load the speech model")
            return [.cancelTimer(.modelLoad), .cancelTimer(.hold), .cancelTimer(.doubleTap), .abortCapture, .startTimer(.dismiss, seconds: config.dismissError)]
        case (.loadingModel, .escape):
            state = .discarded
            return [.cancelTimer(.hold), .cancelTimer(.doubleTap), .cancelTimer(.modelLoad), .abortCapture, .startTimer(.dismiss, seconds: config.dismissDiscarded)]
        case (.armed, .fnDown), (.loadingModel, .fnDown), (.tapped, .fnUp):
            return []

        // ── listening ──
        case (.listening(let l), .fnUp) where l.mode == .pushToTalk:
            return startProcessing(now: now, limitReached: false, cancelling: [.cap, .silence])
        case (.listening(let l), .fnDown) where l.mode == .handsFree:
            return startProcessing(now: now, limitReached: false, cancelling: [.cap, .silence])
        case (.listening(let l), .level(let rms)):
            guard l.mode == .handsFree, rms >= config.voiceRMS else { return [] }
            return [.startTimer(.silence, seconds: config.silenceStop)]
        case (.listening(let l), .timer(.silence)) where l.mode == .handsFree:
            return startProcessing(now: now, limitReached: false, cancelling: [.cap, .silence])
        case (.listening, .timer(.cap)):
            return startProcessing(now: now, limitReached: true, cancelling: [.cap, .silence])
        case (.listening(var l), .languageDetected(let d)):
            l.language = d
            state = .listening(l)
            return []
        case (.listening, .escape):
            state = .discarded
            return [.cancelTimer(.cap), .cancelTimer(.silence), .abortCapture, .startTimer(.dismiss, seconds: config.dismissDiscarded)]
        case (.armed, .escape), (.tapped, .escape):      // esc before the hold/tap decision: nothing to keep
            state = .discarded
            return [.cancelTimer(.hold), .cancelTimer(.doubleTap), .abortCapture, .startTimer(.dismiss, seconds: config.dismissDiscarded)]
        case (.listening, .microphoneFailed(let e)), (.armed, .microphoneFailed(let e)), (.loadingModel, .microphoneFailed(let e)), (.tapped, .microphoneFailed(let e)):
            state = .micUnavailable(Self.access(for: e))
            return [.cancelTimer(.cap), .cancelTimer(.silence), .abortCapture, .startTimer(.dismiss, seconds: config.dismissError)]
        case (.listening, .deviceChanged(name: nil)), (.armed, .deviceChanged(name: nil)),
             (.loadingModel, .deviceChanged(name: nil)), (.tapped, .deviceChanged(name: nil)):
            state = .micUnavailable(.noDevice)
            return [.cancelTimer(.cap), .cancelTimer(.silence), .abortCapture, .startTimer(.dismiss, seconds: config.dismissError)]

        // ── partial text belongs to the current dictation from the moment capture starts ──
        case (.armed, .partialText(let t)), (.tapped, .partialText(let t)), (.loadingModel, .partialText(let t)), (.listening, .partialText(let t)):
            partialText = t
            return []
        case (.processing(var p), .partialText(let t)):
            partialText = t
            p.partialText = t
            state = .processing(p)
            return []

        // ── processing ──
        case (.processing(var p), .timer(.takingLonger)):
            p.takingLonger = true
            state = .processing(p)
            return []
        case (.processing, .timer(.processingTimeout)):
            state = .didntCatch(rawAvailable: !partialText.isEmpty)
            return [.abortCapture, .startTimer(.dismiss, seconds: config.dismissError)]
        case (.processing, .transcriptReady(let text, let low)):
            lastTranscript = text
            let words = Self.wordCount(text)
            let cancel: [FlowBarEffect] = [.cancelTimer(.takingLonger), .cancelTimer(.processingTimeout)]
            if words == 0 || (words < 2 && low) {
                state = .didntCatch(rawAvailable: false)
                return cancel + [.startTimer(.dismiss, seconds: config.dismissError)]
            }
            return cancel + [.insert(text)]
        case (.processing(let p), .insertionFinished(let result)):
            switch result {
            case .inserted(let app):
                state = .inserted(appName: app, words: Self.wordCount(lastTranscript), limitReached: p.limitReached)
                return [.saveHistory, .startTimer(.dismiss, seconds: config.dismissInserted)]
            case .copiedToClipboard(let reason):
                state = .copied(reason)
                return [.saveHistory, .startTimer(.dismiss, seconds: reason == .accessibilityDenied ? config.dismissError : config.dismissCopied)]
            }
        case (.processing, .transcriptionFailed):
            state = .error("Couldn't transcribe")
            return [.cancelTimer(.takingLonger), .cancelTimer(.processingTimeout), .startTimer(.dismiss, seconds: config.dismissError)]
        case (.processing, .escape):
            state = .discarded
            return [.cancelTimer(.takingLonger), .cancelTimer(.processingTimeout), .abortCapture, .startTimer(.dismiss, seconds: config.dismissDiscarded)]

        // ── FB-05 "Copy raw transcript" ──
        case (.didntCatch(rawAvailable: true), .copyRawRequested):
            return [.copyToClipboard(partialText)]

        default:
            return []
        }
    }

    /// Fresh checks authorize capture; gesture delays retain only the time still remaining.
    mutating func resumeMicrophone(_ checks: Preflight, activation: MicrophoneRetryIntent.Activation,
                                  now: TimeInterval) -> [FlowBarEffect] {
        guard state == .idle || state.isDismissable else { return [] }
        var effects = begin(checks, now: now, cancelDismiss: state.isDismissable, mode: activation.mode)
        switch state {
        case .armed(var pending), .loadingModel(var pending):
            let loading = if case .loadingModel = state { true } else { false }
            pending.fnIsDown = activation.fnIsDown
            state = loading ? .loadingModel(pending) : (pending.fnIsDown ? .armed(pending) : .tapped(pending))
            effects.removeAll {
                if case .startTimer(let timer, _) = $0 { return timer == .hold || timer == .doubleTap }
                return false
            }
            if let delay = activation.holdDelay { effects.append(.startTimer(.hold, seconds: delay)) }
            if let delay = activation.doubleTapDelay { effects.append(.startTimer(.doubleTap, seconds: delay)) }
        default: break
        }
        return effects
    }

    private mutating func begin(_ p: Preflight, now: TimeInterval, cancelDismiss: Bool, mode: HotkeyMode? = nil) -> [FlowBarEffect] {
        let prefix: [FlowBarEffect] = cancelDismiss ? [.cancelTimer(.dismiss)] : []
        partialText = ""
        lastTranscript = ""
        if let app = p.excludedApp { state = .excluded(app: app) }
        else if p.secureInput { state = .excluded(app: "a secure field") }
        else if p.microphone != .granted { state = .micUnavailable(p.microphone) }
        else if case .notInstalled(let bytes) = p.model { state = .modelNotInstalled(sizeBytes: bytes) }
        else {
            let pending = Pending(downAt: now, fnIsDown: true, resolvedMode: mode)
            if p.model == .loaded {
                if let mode {
                    state = .listening(Listening(mode: mode, startedAt: now, language: nil))
                    return prefix + [.startCapture, .startTimer(.cap, seconds: config.maxDuration)]
                        + (mode == .handsFree ? [.startTimer(.silence, seconds: config.silenceStop)] : [])
                }
                state = .armed(pending)
                return prefix + [.startCapture, .startTimer(.hold, seconds: config.holdThreshold)]
            }
            state = .loadingModel(pending)
            return prefix + [.startCapture, .loadModel, .startTimer(.modelLoad, seconds: config.modelLoadTimeout)]
                + (mode == nil ? [.startTimer(.hold, seconds: config.holdThreshold)] : [])
        }
        return prefix + [.startTimer(.dismiss, seconds: config.dismissError)]
    }

    private mutating func startProcessing(now: TimeInterval, limitReached: Bool, cancelling: [FlowBarTimer]) -> [FlowBarEffect] {
        state = .processing(Processing(startedAt: now, takingLonger: false, limitReached: limitReached, partialText: partialText))
        return cancelling.map { .cancelTimer($0) } + [.finishCapture,
                .startTimer(.takingLonger, seconds: config.takingLongerAfter),
                .startTimer(.processingTimeout, seconds: config.processingTimeout)]
    }

    private static func access(for error: MicrophoneError) -> MicrophoneAccess {
        switch error {
        case .accessDenied: .denied
        case .noInputDevice: .noDevice
        case .inUse(let app): .inUse(by: app)
        case .engineFailed: .granted
        }
    }
}
