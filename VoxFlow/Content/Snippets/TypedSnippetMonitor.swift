import AppKit
import ApplicationServices
import VoxFlowStyling

/// Expands typed triggers in other apps after their key-down has updated the focused field.
/// Reads the field at key-up instead of retaining a global keystroke buffer across focus changes.
@MainActor
final class TypedSnippetMonitor {
    private let content: ContentService
    private let settings: DictationSettings
    private var monitor: Any?

    init(content: ContentService, settings: DictationSettings) {
        self.content = content
        self.settings = settings
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
            self?.expand(after: event)
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func expand(after event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let typed = event.characters, typed.count == 1,
              !typed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !content.snippetsBox.current.isEmpty,
              AXIsProcessTrusted(), !WorkspaceFrontmostApp().secureInputEnabled(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !settings.excludedBundleIDs.contains(app.bundleIdentifier ?? "") else { return }

        let system = AXUIElementCreateSystemWide()
        guard let focused = attribute(kAXFocusedUIElementAttribute, of: system),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return }
        let field = unsafeDowncast(focused, to: AXUIElement.self)
        var pid: pid_t = 0
        guard AXUIElementGetPid(field, &pid) == .success, pid == app.processIdentifier,
              attribute(kAXSubroleAttribute, of: field) as? String != kAXSecureTextFieldSubrole,
              isSettable(kAXSelectedTextAttribute, of: field),
              isSettable(kAXSelectedTextRangeAttribute, of: field),
              let value = attribute(kAXValueAttribute, of: field) as? String,
              let selected = attribute(kAXSelectedTextRangeAttribute, of: field),
              CFGetTypeID(selected) == AXValueGetTypeID() else { return }
        let selectedValue = unsafeDowncast(selected, to: AXValue.self)
        var selection = CFRange()
        guard AXValueGetType(selectedValue) == .cfRange,
              AXValueGetValue(selectedValue, .cfRange, &selection),
              selection.length == 0, selection.location >= 0, selection.location <= value.utf16.count,
              let range = Range(NSRange(location: selection.location, length: selection.length), in: value),
              value[..<range.lowerBound].hasSuffix(typed) else { return }

        let expander = SnippetExpander(snippets: content.snippetsBox.current, sayPrefix: false,
                                      context: (Date(), NSPasteboard.general.string(forType: .string),
                                                app.localizedName, app.bundleIdentifier))
        guard let expansion = expander.expandTyped(in: value, selection: NSRange(range, in: value)),
              let currentFocus = attribute(kAXFocusedUIElementAttribute, of: system),
              CFEqual(currentFocus, field),
              attribute(kAXValueAttribute, of: field) as? String == value,
              let currentSelection = attribute(kAXSelectedTextRangeAttribute, of: field),
              CFEqual(currentSelection, selected) else { return }
        var replacementRange = CFRange(location: expansion.range.location, length: expansion.range.length)
        guard setSelection(&replacementRange, in: field) else { return }
        guard AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, expansion.text as CFString) == .success else {
            _ = setSelection(&selection, in: field)
            return
        }
        var caret = CFRange(location: expansion.caretUTF16, length: 0)
        _ = setSelection(&caret, in: field)
        Task { await content.noteUses(text: "", snippets: [expansion.trigger]) }
    }

    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func isSettable(_ name: String, of element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }

    private func setSelection(_ range: inout CFRange, in element: AXUIElement) -> Bool {
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }
}
