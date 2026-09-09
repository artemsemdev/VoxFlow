import AppKit
import Foundation
import VoxFlowStorage

/// Case- and diacritic-insensitive fold, mirroring `DictionaryStore`'s own `word_folded` column
/// (that extension is internal to `VoxFlowStorage`, so the app-side duplicate check needs its own
/// copy to compare `sheet.word` against the already-loaded `entries` live, without a round trip).
extension String {
    var foldedForDictionaryMatching: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }
}

/// State and rules of the Dictionary page (design MW-03, 03a, 03v, 03c, 03e). Views render it;
/// nothing else decides. Contacts import (MW-03c) lives in `ContactsImport.swift`, an extension on
/// this class, so the two concerns stay in separate files while sharing one observable model.
@Observable @MainActor
final class DictionaryViewModel {
    /// The "Add word" sheet's draft (design MW-03a) — `editingID` set means "editing this row"
    /// (Add becomes "Save"); nil means a fresh add.
    struct AddWordDraft: Equatable {
        var word: String = ""
        var soundsLike: String = ""
        var type: DictionaryEntryType = .name
        var fixTyping: Bool = false
        var editingID: Int64?
    }

    /// Live validation (design MW-03v), recomputed from `sheet` and `entries` on every access —
    /// there's nothing to debounce, folding+comparing a short word list is instant.
    enum Validation: Equatable {
        case empty
        case duplicate(existing: DictionaryEntry)
    }

    /// "Learn names from Contacts" (design MW-03, MW-03c) — `.off`/`.denied` are followed by the
    /// toggle snapping back off (`stylingSettings.learnFromContacts` reset to false); `.importing` →
    /// `.done(count:)` is one successful import run.
    enum ContactsState: Equatable {
        case off
        case importing
        case done(count: Int)
        case denied
    }

    /// Not `private(set)`: `ContactsImport.swift` (an extension on this class, in a separate file for
    /// readability) writes both from its own methods, so the setter needs to be visible at least
    /// file-locally there too — plain `internal` read/write, same as `sheet` below.
    var entries: [DictionaryEntry] = []
    var sheet: AddWordDraft?
    var contacts: ContactsState = .off

    let content: ContentService
    let contactsImporter: any ContactsImporting
    let stylingSettings: StylingSettings
    let openURL: (URL) -> Void

    /// Set once `observeChanges` has been called — a second `load()` (e.g. navigating back to the
    /// page) must not register a second Contacts change subscription.
    var isObservingContacts = false
    var contactsChangeToken: ContactsChangeToken?

    init(content: ContentService, contactsImporter: any ContactsImporting, stylingSettings: StylingSettings,
         openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.content = content
        self.contactsImporter = contactsImporter
        self.stylingSettings = stylingSettings
        self.openURL = openURL
    }

    // MARK: Derived state

    /// nil while no sheet is up. `.empty` for a blank/whitespace-only word (Add disabled, no
    /// message, design ruling). `.duplicate` when the folded word matches another entry — the
    /// entry currently being edited (`sheet.editingID`) is excluded, since an unchanged word during
    /// an edit isn't a collision with itself.
    var validation: Validation? {
        guard let sheet else { return nil }
        let trimmed = sheet.word.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if let existing = entries.first(where: { $0.word.foldedForDictionaryMatching == trimmed.foldedForDictionaryMatching && $0.id != sheet.editingID }) {
            return .duplicate(existing: existing)
        }
        return nil
    }

    var canAdd: Bool { sheet != nil && validation == nil }

    var isEmpty: Bool { entries.isEmpty }

    // MARK: Load

    func load() async {
        entries = await content.dictionary.all()
        guard stylingSettings.learnFromContacts else { return }
        let result = await runContactsImport(requestIfNeeded: false)
        contacts = result
        if case .done = result {
            observeContactsChangesIfNeeded()
        } else {
            // Permission was revoked since the toggle was last turned on — the toggle can't stay
            // claiming "on" over a state that isn't actually importing anything.
            stylingSettings.learnFromContacts = false
        }
    }

    // MARK: Sheet actions

    func presentAdd() {
        sheet = AddWordDraft()
    }

    func editExisting(_ entry: DictionaryEntry) {
        sheet = AddWordDraft(word: entry.word, soundsLike: entry.soundsLike ?? "", type: entry.type,
                             fixTyping: entry.fixTyping, editingID: entry.id)
    }

    func cancelSheet() {
        sheet = nil
    }

    /// Inserts a new entry, or updates the one being edited (`sheet.editingID`). A no-op when
    /// `canAdd` is false — callers gate the button on it, but this re-checks so a stray call (e.g. a
    /// race with a duplicate landing between keystrokes) can't write invalid state.
    func add() async {
        guard let draft = sheet, canAdd else { return }
        let soundsLike = draft.soundsLike.trimmingCharacters(in: .whitespacesAndNewlines)
        let word = draft.word.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if let id = draft.editingID, let existing = entries.first(where: { $0.id == id }) {
                var updated = existing
                updated.word = word
                updated.soundsLike = soundsLike.isEmpty ? nil : soundsLike
                updated.type = draft.type
                updated.fixTyping = draft.fixTyping
                try await content.dictionary.update(updated)
            } else {
                _ = try await content.dictionary.insert(word: word, soundsLike: soundsLike.isEmpty ? nil : soundsLike,
                                                        type: draft.type, fixTyping: draft.fixTyping)
            }
            entries = await content.dictionary.all()
            sheet = nil
        } catch {
            // A duplicate slipped in between keystroke validation and this write (e.g. two windows) —
            // refresh so `validation` picks it up and shows the same "already in your dictionary"
            // message instead of silently doing nothing.
            entries = await content.dictionary.all()
        }
    }

    func delete(_ entry: DictionaryEntry) {
        entries.removeAll { $0.id == entry.id }
        Task { [content] in
            try? await content.dictionary.delete(id: entry.id)
        }
    }
}
