import Foundation
import VoxFlowStorage

/// Case-insensitive fold for snippet triggers — app-side copy of `SnippetStore`'s internal
/// `trigger_folded`, needed here for live validation against the already-loaded `snippets` without a
/// round trip (same reasoning as `DictionaryViewModel.foldedForDictionaryMatching`). Triggers are
/// plain ASCII (`/word`), so a case fold is enough — no diacritic folding needed.
private extension String {
    var foldedForSnippetMatching: String { lowercased() }
}

/// State and rules of the Snippets page (design MW-04, 04a, 04v, 04e). Views render it; nothing else
/// decides.
@Observable @MainActor
final class SnippetsViewModel {
    /// The "New snippet" sheet's draft (design MW-04a) — `editingID` set means "editing this row"
    /// (Save replaces Add there too, per the brief's copy using "Save" throughout). `onlyIn` is the
    /// checkbox state; `onlyInBundleID`/`onlyInAppName` are only meaningful while it's true.
    struct NewSnippetDraft: Equatable {
        var trigger: String = ""
        var body: String = ""
        var onlyIn: Bool = false
        var onlyInBundleID: String?
        var onlyInAppName: String?
        var editingID: Int64?
    }

    /// Live validation (design MW-04v), recomputed from `sheet` and `snippets` on every access.
    enum Validation: Equatable {
        case empty
        case invalid(suggestion: String)
        case duplicate(existing: Snippet, message: String, suggestion: String)
    }

    var snippets: [Snippet] = []
    var sheet: NewSnippetDraft?

    let content: ContentService
    let stylingSettings: StylingSettings
    let installedApps: any InstalledAppsProviding

    init(content: ContentService, stylingSettings: StylingSettings, installedApps: any InstalledAppsProviding) {
        self.content = content
        self.stylingSettings = stylingSettings
        self.installedApps = installedApps
    }

    var isEmpty: Bool { snippets.isEmpty }

    /// "Say 'snippet' before the trigger" (design MW-04 toggle row).
    var sayPrefix: Bool {
        get { stylingSettings.snippetSayPrefix }
        set { stylingSettings.snippetSayPrefix = newValue }
    }

    /// The installed apps offered by the "Only in {app}" picker.
    var apps: [(bundleID: String, name: String)] { installedApps.installedApps() }

    // MARK: Validation (ruling 7)

    /// nil while no sheet is up. `.empty` for a blank/whitespace-only trigger (Save disabled, no
    /// message). `.duplicate` when the trimmed trigger folds to another snippet's trigger — the
    /// snippet currently being edited (`sheet.editingID`) is excluded. `.invalid` for anything else
    /// that doesn't start with `/` or contains whitespace.
    var validation: Validation? {
        guard let sheet else { return nil }
        let trimmed = sheet.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if let existing = snippets.first(where: {
            $0.trigger.foldedForSnippetMatching == trimmed.foldedForSnippetMatching && $0.id != sheet.editingID
        }) {
            let firstLine = Self.firstLine(of: existing.body)
            return .duplicate(existing: existing,
                              message: "\(trimmed) is already used by \u{201c}\(firstLine)\u{201d}.",
                              suggestion: Self.suggestion(for: trimmed))
        }
        if !Self.isValidFormat(trimmed) {
            return .invalid(suggestion: Self.suggestion(for: trimmed))
        }
        return nil
    }

    var canSave: Bool { sheet != nil && validation == nil }

    /// design MW-04a's "spoken as ..." hint under Say, derived from the trigger — nil while blank.
    var spokenHint: String? {
        guard let sheet else { return nil }
        let trimmed = sheet.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "spoken as \u{201c}slash \(Self.withoutLeadingSlash(trimmed))\u{201d}"
    }

    static func isValidFormat(_ trigger: String) -> Bool {
        trigger.hasPrefix("/") && !trigger.contains(where: \.isWhitespace)
    }

    static func withoutLeadingSlash(_ trigger: String) -> String {
        trigger.hasPrefix("/") ? String(trigger.dropFirst()) : trigger
    }

    /// "Triggers start with / and contain no spaces. Try /sig2 or /work-sig." (ruling 7: `<trigger>2`
    /// and `/work-<trigger without slash>`, both computed against a slash-normalised trigger so the
    /// suggestion makes sense even while the trigger itself is missing its leading `/`).
    static func suggestion(for trigger: String) -> String {
        let normalized = trigger.hasPrefix("/") ? trigger : "/" + trigger
        return "Triggers start with / and contain no spaces. Try \(normalized)2 or /work-\(withoutLeadingSlash(normalized))."
    }

    private static func firstLine(of body: String) -> String {
        body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? body
    }

    // MARK: Load

    func load() async {
        snippets = await content.snippets.all()
    }

    // MARK: Sheet actions

    /// `prefillTrigger` is how the empty state's "Create /sig" opens the sheet pre-filled.
    func presentNew(prefillTrigger: String = "") {
        sheet = NewSnippetDraft(trigger: prefillTrigger)
    }

    func editExisting(_ snippet: Snippet) {
        sheet = NewSnippetDraft(trigger: snippet.trigger, body: snippet.body, onlyIn: snippet.onlyInBundleID != nil,
                                onlyInBundleID: snippet.onlyInBundleID, onlyInAppName: snippet.onlyInAppName, editingID: snippet.id)
    }

    func cancelSheet() {
        sheet = nil
    }

    /// Toggling the "Only in {app}" checkbox on picks the first installed app as a starting point
    /// (so the picker never shows a blank selection); off clears both fields.
    func setOnlyIn(_ enabled: Bool) {
        sheet?.onlyIn = enabled
        if !enabled {
            sheet?.onlyInBundleID = nil
            sheet?.onlyInAppName = nil
        } else if sheet?.onlyInBundleID == nil, let first = apps.first {
            sheet?.onlyInBundleID = first.bundleID
            sheet?.onlyInAppName = first.name
        }
    }

    func chooseOnlyInApp(bundleID: String) {
        guard let name = apps.first(where: { $0.bundleID == bundleID })?.name else { return }
        sheet?.onlyInBundleID = bundleID
        sheet?.onlyInAppName = name
    }

    /// Appends the `cursor` placeholder to the Insert body (design MW-04a's chip). SwiftUI's
    /// `TextEditor` binding doesn't expose caret position, so this always appends at the end rather
    /// than at an arbitrary insertion point — a documented simplification, not a caret tracker.
    func insertCursorPlaceholder() {
        guard var draft = sheet else { return }
        if draft.body.isEmpty || draft.body.hasSuffix("\n") || draft.body.hasSuffix(" ") {
            draft.body += "cursor"
        } else {
            draft.body += " cursor"
        }
        sheet = draft
    }

    /// Inserts a new snippet, or updates the one being edited (`sheet.editingID`). A no-op when
    /// `canSave` is false — callers gate Save on it, but this re-checks so a stray call can't write
    /// invalid state.
    func save() async {
        guard let draft = sheet, canSave else { return }
        let trigger = draft.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let onlyIn: (bundleID: String, appName: String)?
        if draft.onlyIn, let bundleID = draft.onlyInBundleID, let name = draft.onlyInAppName {
            onlyIn = (bundleID, name)
        } else {
            onlyIn = nil
        }
        do {
            if let id = draft.editingID, let existing = snippets.first(where: { $0.id == id }) {
                var updated = existing
                updated.trigger = trigger
                updated.body = draft.body
                updated.onlyInBundleID = onlyIn?.bundleID
                updated.onlyInAppName = onlyIn?.appName
                try await content.snippets.update(updated)
            } else {
                _ = try await content.snippets.insert(trigger: trigger, body: draft.body, onlyIn: onlyIn)
            }
            snippets = await content.snippets.all()
            sheet = nil
        } catch {
            // A duplicate slipped in between keystroke validation and this write — refresh so
            // `validation` picks it up, same reasoning as `DictionaryViewModel.add()`.
            snippets = await content.snippets.all()
        }
    }

    func delete(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
        Task { [content] in
            try? await content.snippets.delete(id: snippet.id)
        }
    }
}
