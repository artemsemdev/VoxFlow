import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// Keeps insertion unit tests independent of real Accessibility processes and permissions.
@MainActor
protocol AccessibilityTextTarget: AnyObject {
    var isEditable: Bool { get }
    var selectedRange: NSRange? { get }
    var textValue: String? { get }
    var supportsLiveInsertion: Bool { get }
    func isSameTarget(as other: any AccessibilityTextTarget) -> Bool
    func replaceSelectedText(_ text: String) -> Bool
    func insertFinalText(_ text: String, isActive: () -> Bool) -> Bool
    func setSelectedRange(_ range: NSRange) -> Bool
}

extension AccessibilityTextTarget {
    var textValue: String? { nil }
    var supportsLiveInsertion: Bool { true }
    func insertFinalText(_ text: String, isActive: () -> Bool) -> Bool {
        isActive() && replaceSelectedText(text)
    }
    func isSameTarget(as other: any AccessibilityTextTarget) -> Bool { self === other }
}

@MainActor
final class AXTextTarget: AccessibilityTextTarget {
    private let element: AXUIElement
    private static var manualAccessibilityRequests: [pid_t: NSRunningApplication] = [:]
    init(_ element: AXUIElement) { self.element = element }

    private var processID: pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        return pid
    }

    var supportsLiveInsertion: Bool {
        guard let pid = processID, let app = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return true }
        return !ChromiumAppFrameworks.containsSupportedFramework(in: app)
    }

    var textValue: String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    func isSameTarget(as other: any AccessibilityTextTarget) -> Bool {
        guard let other = other as? AXTextTarget else { return false }
        return CFEqual(element, other.element)
    }

    static func focused() -> AXTextTarget? {
        prepareFocusedApplication()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return AXTextTarget(unsafeDowncast(focused, to: AXUIElement.self))
    }

    /// Electron documents this per-app flag for assistive software. Only touch the current
    /// recognized Chromium app, and never prompt for permissions or toggle system VoiceOver.
    static func prepareFocusedApplication() {
        // Also prune when focus returns to a native app or permission has been revoked.
        manualAccessibilityRequests = manualAccessibilityRequests.filter { !$0.value.isTerminated }
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              let url = app.bundleURL, ChromiumAppFrameworks.containsSupportedFramework(in: url) else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        let attribute = "AXManualAccessibility" as CFString
        var current: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &current)
        if status == .success, let current, CFEqual(current, kCFBooleanTrue) { return }
        // Electron debounces activation for two seconds; repeated true setters restart that timer.
        // Retain only live application instances so a later process reusing a PID can prepare again.
        guard manualAccessibilityRequests[app.processIdentifier] == nil else { return }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, attribute, &settable) == .success,
              settable.boolValue,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
        if AXUIElementSetAttributeValue(element, attribute, kCFBooleanTrue) == .success {
            manualAccessibilityRequests[app.processIdentifier] = app
        }
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

    func insertFinalText(_ text: String, isActive: () -> Bool) -> Bool {
        guard !supportsLiveInsertion else { return isActive() && replaceSelectedText(text) }
        guard let pid = processID else { return false }
        return UnicodeTextDelivery.deliver(text, to: pid) {
            guard isActive(), AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  self.processID == pid, self.isEditable,
                  let focused = Self.focused(), self.isSameTarget(as: focused) else { return false }
            return isActive()
        }
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
