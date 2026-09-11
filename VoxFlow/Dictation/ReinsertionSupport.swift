import Foundation
import VoxFlowCore
import VoxFlowDictation
import VoxFlowStorage

/// App-side dependencies for Re-insert last. Session results stay in DictationController;
/// this adapter supplies a new insertion target and the optional persisted fallback.
struct ReinsertionSupport: Sendable {
    let frontmost: any FrontmostAppProviding
    let settings: DictationSettingsBox
    let captureFocus: @Sendable (FrontmostApp) async -> Void
    let fetchLatest: @Sendable () async -> DictationRecord?

    func prepareTarget() async -> ReinsertionTarget {
        let app = frontmost.frontmostApp()
        if let gate = privacyGate(app) { return gate }
        await captureFocus(app)
        // Capturing AX focus may hop to the main actor. Do not authorize a snapshot whose
        // app or privacy conditions changed while that capture was suspended.
        let currentApp = frontmost.frontmostApp()
        if let gate = privacyGate(currentApp) { return gate }
        guard currentApp == app else { return .changed }
        return .ready
    }

    private func privacyGate(_ app: FrontmostApp) -> ReinsertionTarget? {
        if let id = app.bundleID, settings.current.excludedBundleIDs.contains(id) {
            return .excluded(app.name ?? id)
        }
        if frontmost.secureInputEnabled() { return .excluded("a secure field") }
        return nil
    }

    func lastSaved() async -> DictationResult? {
        // Do not even open history when it is disabled. A setting changed during the async
        // lookup must also prevent its result from escaping into the current session.
        guard settings.current.keepHistory, !Task.isCancelled else { return nil }
        let record = await fetchLatest()
        guard settings.current.keepHistory, !Task.isCancelled,
              let record, !record.isUnreadable, !record.text.isEmpty else { return nil }
        // History has no segment timing, language confidence or snippet cursor offset. Replay
        // only needs the saved text; leave unavailable recognition metadata unset.
        return DictationResult(text: record.text, rawText: record.rawText, segments: [], language: nil,
                               duration: record.duration, lowConfidence: false, style: record.style)
    }
}
