import AppKit
import VoxFlowStyling

/// Expands typed triggers in VoxFlow's own editor using AppKit's ordinary editing path.
@MainActor
final class InAppTypedSnippetMonitor {
    private let content: ContentService
    private let settings: DictationSettings
    private var monitor: Any?
    private var pending: Task<Void, Never>?

    init(content: ContentService, settings: DictationSettings) {
        self.content = content; self.settings = settings
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.schedule(after: event)
            return event
        }
    }

    func stop() {
        pending?.cancel(); pending = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func schedule(after event: NSEvent) {
        pending?.cancel(); pending = nil
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let typed = event.characters, typed.count == 1,
              !typed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !content.snippetsBox.current.isEmpty,
              let editor = InAppTextTarget.focusedEditor() else { return }
        let target = InAppTextTarget(editor)
        // The main-actor task runs after AppKit dispatches this event into the captured editor.
        pending = Task { [weak self] in
            guard !Task.isCancelled, let self, self.isCurrent(target),
                  let value = target.textValue, let selection = target.selectedRange,
                  selection.length == 0, let range = Range(selection, in: value),
                  value[..<range.lowerBound].hasSuffix(typed) else { return }
            let expander = SnippetExpander(snippets: self.content.snippetsBox.current, sayPrefix: false,
                context: (Date(), NSPasteboard.general.string(forType: .string), "VoxFlow", Bundle.main.bundleIdentifier))
            guard let expansion = expander.expandTyped(in: value, selection: selection),
                  TypedSnippetReplacement.apply(expansion, in: value, selection: selection, target: target,
                    isValid: { self.isCurrent(target) }, sendKeys: { _ in false }) else { return }
            await self.content.noteUses(text: "", snippets: [expansion.trigger])
        }
    }

    private func isCurrent(_ target: InAppTextTarget) -> Bool {
        guard !Task.isCancelled, !WorkspaceFrontmostApp().secureInputEnabled(),
              !settings.excludedBundleIDs.contains(Bundle.main.bundleIdentifier ?? ""),
              let editor = InAppTextTarget.focusedEditor() else { return false }
        return target.isSameTarget(as: InAppTextTarget(editor))
    }
}
