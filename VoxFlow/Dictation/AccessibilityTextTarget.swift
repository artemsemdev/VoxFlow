import ApplicationServices
import Foundation

/// Keeps insertion unit tests independent of real Accessibility processes and permissions.
@MainActor
protocol AccessibilityTextTarget: AnyObject {
    var isEditable: Bool { get }
    var selectedRange: NSRange? { get }
    func replaceSelectedText(_ text: String) -> Bool
    func setSelectedRange(_ range: NSRange) -> Bool
}

@MainActor
final class AXTextTarget: AccessibilityTextTarget {
    private let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }

    static func focused() -> AXTextTarget? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return AXTextTarget(unsafeDowncast(focused, to: AXUIElement.self))
    }

    var isEditable: Bool {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        return EditableRole.isEditable(role: role as? String, selectedTextSettable: settable.boolValue)
    }

    var selectedRange: NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cfRange, &range),
              range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    func replaceSelectedText(_ text: String) -> Bool {
        AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    func setSelectedRange(_ range: NSRange) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }
}
