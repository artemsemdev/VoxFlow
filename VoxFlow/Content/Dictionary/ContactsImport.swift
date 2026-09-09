import AppKit
import Foundation
import Synchronization
import VoxFlowStorage

/// Sendable pipe from `ContactsImporting.observeChanges` (its handler can fire on any thread — real
/// Contacts change notifications aren't main-actor) into `DictionaryViewModel.handleContactsChange()`
/// — same weak-attach shape as `AppServices`' `DictationLevelSink` / `ContentService`'s
/// `ContentUsesSink`, needed because `DictionaryViewModel` itself isn't `Sendable` (it's `@MainActor`).
private final class DictionaryContactsChangeSink: Sendable {
    private struct WeakBox { weak var viewModel: DictionaryViewModel? }
    private let box = Mutex(WeakBox(viewModel: nil))
    func attach(_ viewModel: DictionaryViewModel) { box.withLock { $0.viewModel = viewModel } }
    func fire() {
        Task { @MainActor in self.box.withLock({ $0.viewModel })?.handleContactsChange() }
    }
}

/// "Learn names from Contacts" (design MW-03, MW-03c): the toggle prompts for permission on first
/// use, imports first+last names as dictionary entries, and re-imports whenever Contacts changes
/// while it's on. All of it lives here, off `DictionaryViewModel`'s main file, to keep that one
/// readable — the two share `entries`/`contacts`/`sheet` state on the one `@Observable` instance.
extension DictionaryViewModel {
    /// design MW-03: turning the toggle on requests permission if needed, then imports; denial snaps
    /// the toggle back off and shows the amber row (MW-03c). Turning it off removes every
    /// `source == "contacts"` entry and clears the persisted setting.
    func setLearnFromContacts(_ on: Bool) async {
        guard on else {
            try? await content.dictionary.removeAll(source: "contacts")
            entries = await content.dictionary.all()
            contacts = .off
            stylingSettings.learnFromContacts = false
            return
        }
        let result = await runContactsImport(requestIfNeeded: true)
        contacts = result
        if case .done = result {
            stylingSettings.learnFromContacts = true
            observeContactsChangesIfNeeded()
        } else {
            stylingSettings.learnFromContacts = false   // toggle snaps back to off (design MW-03c)
        }
    }

    /// "Open System Settings" on the denied row (design MW-03c).
    func openContactsSettings() {
        openURL(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")!)
    }

    /// Requests permission if `requestIfNeeded` and authorization is `.notDetermined`, then imports
    /// every Contacts name as a `source: "contacts"` dictionary entry (duplicates — already in the
    /// dictionary under any source — are skipped silently, per ruling 6). Returns `.denied` on
    /// anything short of `.granted`, including a fetch failure (can't confirm the import worked, so
    /// it reads the same as not having access).
    func runContactsImport(requestIfNeeded: Bool) async -> ContactsState {
        var authorization = contactsImporter.authorization()
        if authorization == .notDetermined && requestIfNeeded {
            authorization = await contactsImporter.request()
        }
        guard authorization == .granted else { return .denied }
        contacts = .importing
        do {
            let names = try await contactsImporter.fetchNames()
            for name in names {
                do {
                    _ = try await content.dictionary.insert(word: name, soundsLike: nil, type: .name, fixTyping: false, source: "contacts")
                } catch is StorageError {
                    continue   // already in the dictionary — skip silently (ruling 6)
                }
            }
            entries = await content.dictionary.all()
            return .done(count: names.count)
        } catch {
            return .denied
        }
    }

    /// Registers the Contacts change subscription at most once per view model lifetime.
    func observeContactsChangesIfNeeded() {
        guard !isObservingContacts else { return }
        isObservingContacts = true
        let sink = DictionaryContactsChangeSink()
        sink.attach(self)
        contactsChangeToken = contactsImporter.observeChanges { sink.fire() }
    }

    /// Fired (via `DictionaryContactsChangeSink`) whenever Contacts changes while the toggle is on
    /// (design MW-03c "updates when Contacts change"); a no-op if the toggle has since been turned
    /// off — the subscription itself lives until the view model deallocates, but re-importing into a
    /// dictionary that just asked to stop learning from Contacts would undo that.
    func handleContactsChange() {
        guard stylingSettings.learnFromContacts else { return }
        Task { [weak self] in
            guard let self else { return }
            let result = await self.runContactsImport(requestIfNeeded: false)
            self.contacts = result
        }
    }
}
