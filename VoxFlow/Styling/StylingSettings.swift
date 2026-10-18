import Foundation
import Synchronization
import VoxFlowCore

/// A `Sendable` snapshot of `StylingSettings`, read by `StyledTranscriber` off the main actor —
/// same pattern as `DictationSettingsBox`.
struct StylingSettingsSnapshot: Sendable, Equatable {
    var defaultStyle: TextStyle
    var removeFillers: Bool
    var autoPunctuate: Bool
    var snippetSayPrefix: Bool
}

final class StylingSettingsBox: Sendable {
    private let box: Mutex<StylingSettingsSnapshot>
    init(_ initial: StylingSettingsSnapshot) { box = Mutex(initial) }
    var current: StylingSettingsSnapshot { box.withLock { $0 } }
    func update(_ s: StylingSettingsSnapshot) { box.withLock { $0 = s } }
}

/// Global styling choices (design MW-05 Styles page): the default rewrite tone plus the filler and
/// auto-punctuation toggles that sit under it, whether a snippet trigger requires the spoken
/// "snippet" prefix (design MW-04), and whether the dictionary learns names from Contacts (MW-03).
@Observable @MainActor
final class StylingSettings {
    private let store: any KeyValueStore
    let box: StylingSettingsBox

    enum Keys {
        static let defaultStyle = "styling.default"
    }

    /// Fired from every setting's `didSet` (after persisting and syncing `box`) — lets a live
    /// dictation surface (or a future Styles page) react to a change without polling.
    var onChange: (() -> Void)?

    var defaultStyle: TextStyle { didSet { store.set(defaultStyle.rawValue, forKey: Keys.defaultStyle); sync() } }
    var removeFillers: Bool { didSet { store.set(removeFillers ? "1" : "0", forKey: "styling.removeFillers"); sync() } }
    var autoPunctuate: Bool { didSet { store.set(autoPunctuate ? "1" : "0", forKey: "styling.autoPunctuate"); sync() } }
    var snippetSayPrefix: Bool { didSet { store.set(snippetSayPrefix ? "1" : "0", forKey: "styling.snippetSayPrefix"); sync() } }
    /// "Learn names from Contacts" (design MW-03 toggle) — lives here rather than on a Dictionary
    /// view model so it persists independent of whether that page has ever been opened.
    var learnFromContacts: Bool { didSet { store.set(learnFromContacts ? "1" : "0", forKey: "styling.learnFromContacts"); sync() } }

    init(store: any KeyValueStore) {
        // M7: read into locals first, then assign both the stored properties and the box from the
        // same values — `self.defaultStyle` etc. can't be read back yet (`box` isn't initialized
        // until the two-phase init finishes), and seeding the box from separate literal defaults
        // instead (the old code) meant those literals could silently drift from these.
        let loadedDefaultStyle = store.string(forKey: Keys.defaultStyle).flatMap(TextStyle.init(rawValue:)) ?? .casual
        let loadedRemoveFillers = store.string(forKey: "styling.removeFillers") != "0"
        let loadedAutoPunctuate = store.string(forKey: "styling.autoPunctuate") != "0"
        let loadedSnippetSayPrefix = store.string(forKey: "styling.snippetSayPrefix") == "1"

        self.store = store
        defaultStyle = loadedDefaultStyle
        removeFillers = loadedRemoveFillers
        autoPunctuate = loadedAutoPunctuate
        snippetSayPrefix = loadedSnippetSayPrefix
        learnFromContacts = store.string(forKey: "styling.learnFromContacts") == "1"
        box = StylingSettingsBox(StylingSettingsSnapshot(defaultStyle: loadedDefaultStyle, removeFillers: loadedRemoveFillers,
                                                          autoPunctuate: loadedAutoPunctuate, snippetSayPrefix: loadedSnippetSayPrefix))
        sync()
    }

    var snapshot: StylingSettingsSnapshot { box.current }

    private func sync() {
        box.update(StylingSettingsSnapshot(defaultStyle: defaultStyle, removeFillers: removeFillers, autoPunctuate: autoPunctuate,
                                           snippetSayPrefix: snippetSayPrefix))
        onChange?()
    }
}
