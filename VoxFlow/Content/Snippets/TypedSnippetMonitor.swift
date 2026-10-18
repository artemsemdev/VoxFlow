import AppKit
import ApplicationServices
import VoxFlowStyling

/// Observe supported global key-down events, then read the updated field after the editor settles.
/// Retains no keystroke buffer and cancels pending work on subsequent input or focus changes.
@MainActor
final class TypedSnippetMonitor {
    private let content: ContentService
    private let settings: DictationSettings
    private var monitor: Any?
    private var pending: Task<Void, Never>?

    init(content: ContentService, settings: DictationSettings) {
        self.content = content
        self.settings = settings
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.schedule(after: event)
        }
    }

    func stop() {
        pending?.cancel()
        pending = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func schedule(after event: NSEvent) {
        guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != TypedSnippetReplacement.eventMarker else { return }
        pending?.cancel()
        pending = nil
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let typed = event.characters, typed.count == 1,
              !typed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !content.snippetsBox.current.isEmpty,
              AXIsProcessTrusted(), !WorkspaceFrontmostApp().secureInputEnabled(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !settings.excludedBundleIDs.contains(app.bundleIdentifier ?? "") else { return }

        AXTextTarget.prepareFocusedApplication()
        let system = AXUIElementCreateSystemWide()
        guard let focused = attribute(kAXFocusedUIElementAttribute, of: system),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return }
        let field = unsafeDowncast(focused, to: AXUIElement.self)
        let target = AXTextTarget(field)
        guard target.isEditable else { return }
        pending = Task { [weak self] in
            // Global event delivery can precede the editor's text update. A newer key or mouse
            // event cancels this short debounce; the captured field must still own focus.
            do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
            guard !Task.isCancelled, let self, self.isCurrent(target, app: app) else { return }
            self.expand(typed: typed, field: field, target: target, app: app)
        }
    }

    private func isCurrent(_ target: AXTextTarget, app: NSRunningApplication) -> Bool {
        guard !Task.isCancelled, AXIsProcessTrusted(), !WorkspaceFrontmostApp().secureInputEnabled(),
              !app.isTerminated, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              !settings.excludedBundleIDs.contains(app.bundleIdentifier ?? ""),
              let current = AXTextTarget.focused() else { return false }
        return target.isSameTarget(as: current)
    }

    private func expand(typed: String, field: AXUIElement, target: AXTextTarget, app: NSRunningApplication) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(field, &pid) == .success, pid == app.processIdentifier,
              attribute(kAXSubroleAttribute, of: field) as? String != kAXSecureTextFieldSubrole,
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
        guard let expansion = expander.expandTyped(in: value, selection: NSRange(range, in: value)) else { return }
        let isValid = { self.isCurrent(target, app: app) }
        guard TypedSnippetReplacement.apply(expansion, in: value, selection: NSRange(range, in: value),
            target: target, isValid: isValid, sendKeys: {
                TypedSnippetReplacement.deliver($0, to: app.processIdentifier, isValid: isValid)
            }) else { return }
        Task { await content.noteUses(text: "", snippets: [expansion.trigger]) }
    }

    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

}
