import AppKit
import ApplicationServices
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

    init(permissions: any PermissionChecking, pasteboard: any Pasteboard) {
        self.permissions = permissions
        self.pasteboard = pasteboard
    }

    nonisolated func captureFocus() { Task { @MainActor in self.capture() } }

    private func capture() {
        target = nil
        appName = NSWorkspace.shared.frontmostApplication?.localizedName
        guard permissions.accessibilityTrusted(prompt: true) else { return }
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
