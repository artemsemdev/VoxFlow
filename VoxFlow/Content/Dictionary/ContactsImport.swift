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
    ///
    /// F7: bumps `contactsGeneration` first, so a toggle-off that arrives while an "on" import from an
    /// earlier call is still in flight invalidates it — once that stale import's `runContactsImport`
    /// finally returns, it notices the generation moved on and cleans up (`removeAll(source:
    /// "contacts")`) instead of applying its (now obsolete) result over the "off" state this call just
    /// established.
    func setLearnFromContacts(_ on: Bool) async {
        contactsGeneration += 1
        let generation = contactsGeneration
        guard on else {
            try? await content.dictionary.removeAll(source: "contacts")
            entries = await content.dictionary.all()
            // Guarded the same way as every mid-flight write below: an even newer generation
            // (another toggle tap while this "off" was still awaiting its own removal) owns `contacts`
            // now, not this one.
            if generation == contactsGeneration { contacts = .off }
            stylingSettings.learnFromContacts = false
            return
        }
        let result = await runContactsImport(requestIfNeeded: true, generation: generation)
        guard generation == contactsGeneration else {
            await discardStaleImport()
            return
        }
        applyContactsResult(result)
    }

    /// "Open System Settings" on the denied row (design MW-03c).
    func openContactsSettings() {
        openURL(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")!)
    }

    /// `.done` keeps the toggle on (persists the setting, starts observing Contacts changes if it
    /// isn't already); anything else (`.denied`, or a fetch failure — `runContactsImport` folds both
    /// into `.denied`) snaps the toggle back off (F5) — shared by every caller (`load()`,
    /// `setLearnFromContacts(true)`, `handleContactsChange()`) so a permission revoked at any point is
    /// handled identically instead of only on the paths someone remembered to write it for.
    func applyContactsResult(_ result: ContactsState) {
        contacts = result
        if case .done = result {
            stylingSettings.learnFromContacts = true
            observeContactsChangesIfNeeded()
        } else {
            stylingSettings.learnFromContacts = false
        }
    }

    /// A `runContactsImport` call this generation no longer belongs to (F7) already wrote whatever it
    /// managed to insert before losing the race — undo that rather than leaving orphaned `source:
    /// "contacts"` rows behind a toggle that now reads "off". Doesn't touch `contacts` itself: whatever
    /// generation is current by now (the one that superseded this import) already owns it, having set
    /// it the same way this function's own caller would have.
    private func discardStaleImport() async {
        try? await content.dictionary.removeAll(source: "contacts")
        entries = await content.dictionary.all()
    }

    /// Requests permission if `requestIfNeeded` and authorization is `.notDetermined`, then imports
    /// every Contacts name as a `source: "contacts"` dictionary entry (duplicates — already in the
    /// dictionary under any source — are skipped silently, per ruling 6). Returns `.denied` on
    /// anything short of `.granted`, including a fetch failure (can't confirm the import worked, so
    /// it reads the same as not having access).
    ///
    /// F2: `contacts` is set to `.importing(count: nil)` before the fetch (nothing to show a count for
    /// yet) and to `.importing(count: names.count)` right after it resolves, *before* the per-name
    /// insert loop — the insert loop is fast, local SQLite writes, so by the time a user could
    /// plausibly notice the row, the real count is already showing.
    ///
    /// F7: every mid-flight write to `contacts`/`entries` here is guarded by `generation ==
    /// contactsGeneration` — `contactsGeneration` at call time is passed in explicitly rather than
    /// re-read, since the caller captured it before this function's first `await` (the only point at
    /// which a newer generation could start). Without these guards, a stale call resumed by
    /// `unblock()` after a toggle-off would flash `.importing`/write to `entries` again on its way to
    /// noticing it lost the race, even though the top-level `guard generation == contactsGeneration`
    /// in each caller already discards its *result* — the mid-flight writes needed their own guard.
    func runContactsImport(requestIfNeeded: Bool, generation: Int) async -> ContactsState {
        var authorization = contactsImporter.authorization()
        if authorization == .notDetermined && requestIfNeeded {
            authorization = await contactsImporter.request()
        }
        guard authorization == .granted else { return .denied }
        if generation == contactsGeneration { contacts = .importing(count: nil) }
        do {
            let names = try await contactsImporter.fetchNames()
            if generation == contactsGeneration { contacts = .importing(count: names.count) }
            for name in names {
                do {
                    _ = try await content.dictionary.insert(word: name, soundsLike: nil, type: .name, fixTyping: false, source: "contacts")
                } catch is StorageError {
                    continue   // already in the dictionary — skip silently (ruling 6)
                }
            }
            if generation == contactsGeneration { entries = await content.dictionary.all() }
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
    /// dictionary that just asked to stop learning from Contacts would undo that. Uses the same
    /// generation guard and `applyContactsResult` as `load()`/`setLearnFromContacts` (F5/F7): a
    /// revoked permission snaps the toggle back off here too, and a toggle flip that lands mid-fetch
    /// supersedes this attempt instead of racing it.
    func handleContactsChange() {
        guard stylingSettings.learnFromContacts else { return }
        contactsGeneration += 1
        let generation = contactsGeneration
        Task { [weak self] in
            guard let self else { return }
            let result = await self.runContactsImport(requestIfNeeded: false, generation: generation)
            guard generation == self.contactsGeneration else {
                await self.discardStaleImport()
                return
            }
            self.applyContactsResult(result)
        }
    }
}
