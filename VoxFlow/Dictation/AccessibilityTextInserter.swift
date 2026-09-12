import ApplicationServices
import Foundation
import VoxFlowCore

enum EditableRole {
    static let roles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    static func isEditable(role: String?, selectedTextSettable: Bool) -> Bool {
        selectedTextSettable || role.map(roles.contains) == true
    }
}

/// Writes dictated text into the field that had focus at fn-down (rulings 2–3); clipboard otherwise (FB-04b).
@MainActor
final class AccessibilityTextInserter: TextInserting {
    private let permissions: any PermissionChecking
    private let pasteboard: any Pasteboard
    private var target: (any AccessibilityTextTarget)?
    private let focusTarget: @MainActor () -> (any AccessibilityTextTarget)?
    private var appName: String?
    /// M-1: macOS does not reliably one-shot the Accessibility prompt per process, so without this
    /// `capture()` would ask again on *every* fn-down — including the ones the machine ignores
    /// (`.armed`/`.loadingModel` fn-downs). Prompt once per launch; every later capture uses
    /// `prompt: false`.
    private var hasPrompted = false

    init(permissions: any PermissionChecking, pasteboard: any Pasteboard,
         focusTarget: @escaping @MainActor () -> (any AccessibilityTextTarget)? = { AXTextTarget.focused() }) {
        self.permissions = permissions
        self.pasteboard = pasteboard
        self.focusTarget = focusTarget
    }

    /// I-5: takes the `FrontmostApp` `PreflightBuilder` already read and checked against the
    /// excluded-apps list, instead of re-reading `NSWorkspace` here — the two reads could disagree
    /// if the frontmost app changed between the exclusion check and this call. `nonisolated` + `async`
    /// so a non-actor caller (`PreflightBuilder`, itself `Sendable`) can `await` straight through to
    /// the `MainActor`-isolated `capture(app:)` — no fire-and-forget `Task` hop.
    nonisolated func captureFocus(app: FrontmostApp) async { await capture(app: app) }

    private func capture(app: FrontmostApp) {
        target = nil
        appName = app.name
        let prompt = !hasPrompted
        let trusted = permissions.accessibilityTrusted(prompt: prompt)
        if prompt { hasPrompted = true }
        guard trusted else { return }
        target = focusTarget()
    }

    nonisolated func insert(_ text: String, cursorOffset: Int?) async -> InsertionResult {
        await MainActor.run { self.performInsert(text, cursorOffset: cursorOffset) }
    }

    private func performInsert(_ text: String, cursorOffset: Int?) -> InsertionResult {
        defer { target = nil }
        guard permissions.accessibilityTrusted(prompt: false) else {
            return copy(text, reason: .accessibilityDenied)
        }
        if let target, target.isEditable {
            // Read the replacement's start before writing: most targets move selection to its end.
            let selection = cursorOffset == nil ? nil : target.selectedRange
            if target.replaceSelectedText(text) {
                if let offset = cursorOffset, offset >= 0, offset <= text.count,
                   let start = selection?.location, start >= 0, start != NSNotFound {
                    let (position, overflow) = start.addingReportingOverflow(text.prefix(offset).utf16.count)
                    if !overflow { _ = target.setSelectedRange(NSRange(location: position, length: 0)) }
                }
                return .inserted(appName: appName)
            }
            return copy(text, reason: .insertionFailed)
        }
        return copy(text, reason: .noTextField)
    }

    private func copy(_ text: String, reason: CopyReason) -> InsertionResult {
        pasteboard.setString(text)
        return .copiedToClipboard(reason: reason)
    }
}
