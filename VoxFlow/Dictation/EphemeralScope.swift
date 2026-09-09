import Synchronization

/// Tracks whether a scratchpad-style "try it" surface — onboarding's ONB-05 step, or History's "Try
/// it in a scratchpad" sheet — is currently on screen. `AppServices` passes `{ scope.isActive }` as
/// `DictationController`'s `ephemeral:` closure, which reads it once at the start of every capture
/// (I-1/I-2/I-3): a capture that starts while the scope is active is never written to History.
///
/// Any dictation started while the scope is active — even one triggered from another app via the
/// global fn-key monitor, not the scratchpad itself — is not saved. The scope is only active while a
/// scratchpad is actually on screen; it has no idea (and no opinion) about which app was frontmost
/// when the capture started.
///
/// A `Mutex<Int>` depth counter, not a `Bool`: `enter()`/`leave()` are called from independent
/// call sites (onboarding's Try It step and History's scratchpad sheet), which can be up at the same
/// time in the same session (the main window is reachable from the menu bar during onboarding) — a
/// depth counter keeps the scope active until every `enter()` has a matching `leave()`, instead of
/// one owner's `leave()` silently deactivating a scope the other owner is still relying on.
final class EphemeralScope: Sendable {
    private let depth = Mutex(0)

    /// True while at least one caller has entered and not yet left.
    var isActive: Bool { depth.withLock { $0 > 0 } }

    func enter() { depth.withLock { $0 += 1 } }

    /// Balances a prior `enter()`. Never goes negative — an unmatched `leave()` is a no-op rather
    /// than corrupting the count for every other caller.
    func leave() { depth.withLock { $0 = max(0, $0 - 1) } }
}
