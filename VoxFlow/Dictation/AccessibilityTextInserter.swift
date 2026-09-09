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
    private var target: AXUIElement?
    private var appName: String?
    /// M-1: macOS does not reliably one-shot the Accessibility prompt per process, so without this
    /// `capture()` would ask again on *every* fn-down — including the ones the machine ignores
    /// (`.armed`/`.loadingModel` fn-downs). Prompt once per launch; every later capture uses
    /// `prompt: false`.
    private var hasPrompted = false

    init(permissions: any PermissionChecking, pasteboard: any Pasteboard) {
        self.permissions = permissions
        self.pasteboard = pasteboard
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
        var focused: CFTypeRef?
        let system = AXUIElementCreateSystemWide()
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return }
        target = unsafeDowncast(element, to: AXUIElement.self)
    }

    nonisolated func insert(_ text: String) async -> InsertionResult {
        await MainActor.run { self.performInsert(text) }
    }

    private func performInsert(_ text: String) -> InsertionResult {
        defer { target = nil }
        if let target, permissions.accessibilityTrusted(prompt: false), Self.isEditable(target) {
            let status = AXUIElementSetAttributeValue(target, kAXSelectedTextAttribute as CFString, text as CFString)
            if status == .success { return .inserted(appName: appName) }
        }
        pasteboard.setString(text)
        return .copiedToClipboard
    }

    private static func isEditable(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        return EditableRole.isEditable(role: role as? String, selectedTextSettable: settable.boolValue)
    }
}
