import Foundation

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
}
