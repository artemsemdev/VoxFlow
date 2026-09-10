import Foundation
import VoxFlowDictation

/// User-facing MCP tool error copy (Phase 6) — the exact strings the brief specifies, tested
/// verbatim so the wording can't drift silently between `MCPToolRunner` and its tests. Every other
/// tool-failure message is dynamic and rides through as-is from its own source instead of living
/// here: a `PathPolicy.Rejection`'s own `message`, a transcription failure's own description
/// (`String(describing:)`, same convention `DictationController` already uses for transcription/
/// microphone failures), and `HistoryViewModel.readableReason`'s output.
enum MCPToolError {
    /// `dictate` while `DictationCoordinator.isHUDActive` — a capture is already in progress.
    static let dictationAlreadyRunning = "A dictation is already running."
    /// `dictate` while `DictationCoordinator.pausedUntil != nil` — an FB-09 pause is active.
    static let dictationPaused = "Dictation is paused."
    /// `dictate` when no `DictationController.results()` element arrives before
    /// `FlowBarConfig.maxDuration + .processingTimeout` elapses on the injected clock.
    static let dictationTimedOut = "Dictation timed out."

    /// `dictate`'s fast-failure path (Task 3 review item 6): `nil` for every state that either
    /// still might produce a result (`.idle`, `.armed`, `.tapped`, `.listening`, `.processing`,
    /// `.loadingModel`, `.paused`) or *did* produce one (`.inserted`, `.copied` — those reach
    /// `MCPToolRunner.dictate()` via `results()`, not this table). Non-`nil` for every terminal
    /// state that ends a capture with no result at all — `MCPError.captureFailed` (`-32005`) is
    /// returned with this exact string. `.discarded`/`.didntCatch`/`.micUnavailable` variants/
    /// `.excluded`/`.modelNotInstalled` are fixed copy (tested verbatim); `.error`'s message is
    /// whatever `DictationController` reported (a model-load or transcription failure's own
    /// description) and rides through as-is.
    static func dictationFailureReason(for state: FlowBarState) -> String? {
        switch state {
        case .discarded: return "Dictation was discarded."
        case .didntCatch: return "VoxFlow didn't catch that."
        case .error(let message): return message
        case .micUnavailable(let access): return microphoneUnavailableReason(access)
        case .excluded(let app): return "Dictation is off in \(app)."
        case .modelNotInstalled: return "The speech model isn't installed."
        default: return nil
        }
    }

    private static func microphoneUnavailableReason(_ access: MicrophoneAccess) -> String {
        switch access {
        case .denied: return "Microphone access needed."
        case .noDevice: return "No microphone."
        case .inUse(let app): return app.map { "Microphone in use by \($0)." } ?? "Microphone in use by another app."
        case .granted: return "Microphone unavailable."
        }
    }
}
