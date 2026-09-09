import VoxFlowDictation

/// Pure decision logic behind MB-00 (design page 4: "once, after onboarding; auto-dismiss 10 s or
/// on first dictation") — kept separate from `MenuBarHintPanel`/`MenuBarServices` (which own the
/// actual timer/observation/panel side effects) so the two decisions it makes are unit-testable
/// without a real `NSPanel` or a `Task.sleep`.
enum MenuBarHintPolicy {
    /// Shown once, right after onboarding finishes — never again once `hintShown` is persisted.
    /// M4: also gated on `showInMenuBar` — someone who turned the menu bar item off before
    /// finishing onboarding must not get a hint pointing at an empty menu bar.
    static func shouldShow(hintShown: Bool, showInMenuBar: Bool) -> Bool { !hintShown && showInMenuBar }

    /// Auto-dismisses the instant a real dictation starts (fn pressed, or already listening) — not
    /// any other Flow Bar activity (e.g. an error/warning pill from a previous, already-dismissed
    /// hint shouldn't matter here; this only cares about "the person just dictated").
    static func shouldDismiss(for state: FlowBarState) -> Bool {
        switch state {
        case .armed, .tapped, .listening: true
        default: false
        }
    }
}
