import CryptoKit
import Foundation
import Testing
import VoxFlowCore
import VoxFlowStorage
import VoxFlowTestSupport
@testable import VoxFlow

private struct FakeDictionaryKeyProvider: HistoryKeyProviding {
    let key = SymmetricKey(size: .bits256)
    func historyKey() throws -> HistoryKey { HistoryKey(key: key, isNewlyCreated: false) }
}

@Suite("DictionaryViewModel", .timeLimit(.minutes(1)))
@MainActor
struct DictionaryViewModelTests {
    @MainActor
    struct Harness {
        let dir = TemporaryDirectory()
        let settings: StylingSettings
        let service: HistoryService
        let content: ContentService
        var openedURLs: [URL] = []

        init() {
            settings = StylingSettings(store: InMemoryKeyValueStore())
            service = HistoryService(url: dir.file("voxflow.sqlite"), settings: DictationSettings(store: InMemoryKeyValueStore()),
                                     keyProvider: { FakeDictionaryKeyProvider() }, clock: SystemMonotonicClock())
            content = ContentService(history: service)
        }

        func vm(contacts: any ContactsImporting = FakeContacts()) -> DictionaryViewModel {
            DictionaryViewModel(content: content, contactsImporter: contacts, stylingSettings: settings, openURL: { _ in })
        }
    }

    /// No-sleep poll, same technique `HistoryViewModelTests` uses.
    private func waitFor(_ predicate: () -> Bool) async {
        for _ in 0..<2_000 where !predicate() { await Task.yield() }
    }

    // MARK: Add / validation

    @Test("add inserts a new entry and closes the sheet")
    func addInsertsEntry() async throws {
        let h = Harness()
        let vm = h.vm()
        await vm.load()
        vm.presentAdd()
        vm.sheet?.word = "Kubernetes"
        vm.sheet?.soundsLike = "koo-ber-net-eez"
        vm.sheet?.type = .term

        await vm.add()

        #expect(vm.sheet == nil)
        #expect(vm.entries.map(\.word) == ["Kubernetes"])
        #expect(vm.entries[0].soundsLike == "koo-ber-net-eez")
        #expect(vm.entries[0].type == .term)
    }

    @Test("validation is .empty for a blank word — Add disabled, no message")
    func emptyValidation() {
        let h = Harness()
        let vm = h.vm()
        vm.presentAdd()

        #expect(vm.validation == .empty)
        #expect(vm.canAdd == false)

        vm.sheet?.word = "   "
        #expect(vm.validation == .empty)
    }

    @Test("validation is .duplicate (case-insensitive) for a word already in the dictionary — Add disabled")
    func duplicateValidation() async throws {
        let h = Harness()
        let vm = h.vm()
        await vm.load()
        vm.presentAdd()
        vm.sheet?.word = "Kubernetes"
        await vm.add()

        vm.presentAdd()
        vm.sheet?.word = "kubernetes"   // different case — still a duplicate (folded match)

        guard case .duplicate(let existing, let typed) = vm.validation else {
            Issue.record("expected .duplicate, got \(String(describing: vm.validation))")
            return
        }
        #expect(existing.word == "Kubernetes")
        #expect(vm.canAdd == false)
        // F3: the message quotes what was *typed*, not the stored entry's casing.
        #expect(typed == "kubernetes")
    }

    @Test("F3: the duplicate message quotes the typed word (as typed, trimmed) in straight quotes")
    func duplicateMessageQuotesTypedWord() async throws {
        let h = Harness()
        let vm = h.vm()
        await vm.load()
        vm.presentAdd()
        vm.sheet?.word = "Kubernetes"
        await vm.add()

        vm.presentAdd()
        vm.sheet?.word = "  kubernetes  "   // extra whitespace — trimmed, but casing as typed

        guard case .duplicate(_, let typed) = vm.validation else {
            Issue.record("expected .duplicate, got \(String(describing: vm.validation))")
            return
        }
        #expect(typed == "kubernetes")
    }

    /// F4: `DictionaryViewModel`'s local `String.foldedForDictionaryMatching` must keep matching
    /// `DictionaryStore`'s `word_folded` semantics (case + diacritic insensitive) — this pass couldn't
    /// expose the storage-internal fold as `public` (out of its file scope), so this pins the two
    /// implementations to the same result set on the exact cases `DictionaryStoreTests` exercises, so
    /// a drift between them fails a test instead of silently producing wrong validation.
    @Test("F4: the local fold matches DictionaryStore's word_folded semantics — case and diacritic insensitive")
    func foldedMatchingPinnedToStorageSemantics() {
        #expect("Kubernetes".foldedForDictionaryMatching == "kubernetes".foldedForDictionaryMatching)
        #expect("Tāmaki".foldedForDictionaryMatching == "Tamaki".foldedForDictionaryMatching)
        #expect("VoxFlow".foldedForDictionaryMatching != "Snowflake".foldedForDictionaryMatching)
    }

    @Test("Edit existing prefills the sheet with the existing entry, in edit mode")
    func editExistingFromDuplicate() async throws {
        let h = Harness()
        let vm = h.vm()
        await vm.load()
        vm.presentAdd()
        vm.sheet?.word = "Kubernetes"
        vm.sheet?.soundsLike = "koo"
        vm.sheet?.type = .term
        await vm.add()
        let existing = vm.entries[0]

        vm.editExisting(existing)

        #expect(vm.sheet?.word == "Kubernetes")
        #expect(vm.sheet?.soundsLike == "koo")
        #expect(vm.sheet?.type == .term)
        #expect(vm.sheet?.editingID == existing.id)
        // Editing the entry itself is not a self-collision.
        #expect(vm.validation == nil)
        #expect(vm.canAdd == true)
    }

    @Test("editing and saving updates the entry in place rather than inserting a new one")
    func editSavesInPlace() async throws {
        let h = Harness()
        let vm = h.vm()
        await vm.load()
        vm.presentAdd()
        vm.sheet?.word = "Kubernetes"
        await vm.add()
        let existing = vm.entries[0]

        vm.editExisting(existing)
        vm.sheet?.soundsLike = "koo-ber-net-eez"
        await vm.add()

        #expect(vm.entries.count == 1)
        #expect(vm.entries[0].id == existing.id)
        #expect(vm.entries[0].soundsLike == "koo-ber-net-eez")
    }

    // MARK: Delete

    @Test("delete removes the entry locally and from storage")
    func deleteRemovesEntry() async throws {
        let h = Harness()
        let vm = h.vm()
        await vm.load()
        vm.presentAdd()
        vm.sheet?.word = "Kubernetes"
        await vm.add()
        let entry = vm.entries[0]

        vm.delete(entry)

        #expect(vm.entries.isEmpty)
        var remaining = await h.content.dictionary.all()
        for _ in 0..<2_000 where !remaining.isEmpty {
            await Task.yield()
            remaining = await h.content.dictionary.all()
        }
        #expect(remaining.isEmpty)
    }

    // MARK: Contacts

    @Test("granted contacts import adds entries with source contacts and reports .done(count)")
    func contactsGrantedImports() async throws {
        let h = Harness()
        let contacts = FakeContacts(authorization: .granted, names: ["Anh Nguyen", "Priya Raghunathan"])
        let vm = h.vm(contacts: contacts)
        await vm.load()

        await vm.setLearnFromContacts(true)

        #expect(vm.contacts == .done(count: 2))
        #expect(h.settings.learnFromContacts == true)
        #expect(Set(vm.entries.map(\.word)) == ["Anh Nguyen", "Priya Raghunathan"])
        #expect(vm.entries.allSatisfy { $0.source == "contacts" })
        #expect(vm.entries.allSatisfy { $0.type == .name })
    }

    @Test("notDetermined authorization requests permission before importing")
    func contactsNotDeterminedRequests() async throws {
        let h = Harness()
        let contacts = FakeContacts(authorization: .notDetermined, requestResult: .granted, names: ["Anh Nguyen"])
        let vm = h.vm(contacts: contacts)
        await vm.load()

        await vm.setLearnFromContacts(true)

        #expect(contacts.requests == 1)
        #expect(vm.contacts == .done(count: 1))
    }

    @Test("denied authorization sets .denied and snaps the toggle back to off")
    func contactsDeniedSnapsBack() async throws {
        let h = Harness()
        let contacts = FakeContacts(authorization: .denied)
        let vm = h.vm(contacts: contacts)
        await vm.load()

        await vm.setLearnFromContacts(true)

        #expect(vm.contacts == .denied)
        #expect(h.settings.learnFromContacts == false)
        #expect(vm.entries.isEmpty)
    }

    @Test("turning the toggle off removes every contacts-sourced entry, keeping user entries")
    func togglingOffRemovesContactsEntries() async throws {
        let h = Harness()
        let contacts = FakeContacts(authorization: .granted, names: ["Anh Nguyen"])
        let vm = h.vm(contacts: contacts)
        await vm.load()
        vm.presentAdd()
        vm.sheet?.word = "Kubernetes"
        await vm.add()
        await vm.setLearnFromContacts(true)
        #expect(vm.entries.count == 2)

        await vm.setLearnFromContacts(false)

        #expect(vm.contacts == .off)
        #expect(h.settings.learnFromContacts == false)
        #expect(vm.entries.map(\.word) == ["Kubernetes"])
    }

    @Test("a duplicate contact name (already a user entry) is skipped silently, not double-added")
    func contactsSkipsDuplicates() async throws {
        let h = Harness()
        let vm0 = h.vm()
        await vm0.load()
        vm0.presentAdd()
        vm0.sheet?.word = "Anh Nguyen"
        await vm0.add()

        let contacts = FakeContacts(authorization: .granted, names: ["Anh Nguyen", "Priya Raghunathan"])
        let vm = h.vm(contacts: contacts)
        await vm.load()

        await vm.setLearnFromContacts(true)

        #expect(vm.entries.map(\.word).sorted() == ["Anh Nguyen", "Priya Raghunathan"])
        // The pre-existing "Anh Nguyen" (user-added) is untouched — still source "user".
        #expect(vm.entries.first { $0.word == "Anh Nguyen" }?.source == "user")
    }

    @Test("load() re-imports from Contacts when learnFromContacts was already on from a previous launch")
    func loadReimportsWhenAlreadyOn() async throws {
        let h = Harness()
        h.settings.learnFromContacts = true
        let contacts = FakeContacts(authorization: .granted, names: ["Anh Nguyen"])
        let vm = h.vm(contacts: contacts)

        await vm.load()

        #expect(vm.contacts == .done(count: 1))
        #expect(vm.entries.map(\.word) == ["Anh Nguyen"])
    }

    @Test("load() turns the setting back off when permission was revoked since the last launch")
    func loadTurnsOffWhenRevoked() async throws {
        let h = Harness()
        h.settings.learnFromContacts = true
        let contacts = FakeContacts(authorization: .denied)
        let vm = h.vm(contacts: contacts)

        await vm.load()

        #expect(vm.contacts == .denied)
        #expect(h.settings.learnFromContacts == false)
    }

    @Test("a Contacts change notification re-imports while the toggle is on")
    func contactsChangeReimports() async throws {
        let h = Harness()
        let contacts = FakeContacts(authorization: .granted, names: ["Anh Nguyen"])
        let vm = h.vm(contacts: contacts)
        await vm.load()
        await vm.setLearnFromContacts(true)
        #expect(vm.entries.count == 1)

        contacts.setNames(["Anh Nguyen", "Priya Raghunathan"])
        contacts.fireChange()

        await waitFor { vm.entries.count == 2 }
        #expect(vm.contacts == .done(count: 2))
    }

    /// F2: the fetch resolves before the (fast) insert loop runs, and `.importing(count:)` reflects
    /// the real fetched count at that point — not 0, and not derived from `entries`.
    @Test("F2: .importing carries nil while fetching, then the real count once the fetch resolves")
    func importingCarriesRealCount() async throws {
        let h = Harness()
        let blocking = BlockingFakeContacts(names: ["Anh Nguyen", "Priya Raghunathan", "Kubernetes"])
        let vm = h.vm(contacts: blocking)
        await vm.load()

        let task = Task { await vm.setLearnFromContacts(true) }
        await waitFor { vm.contacts == .importing(count: nil) }   // still fetching — no count yet

        blocking.unblock()
        await waitFor { vm.contacts != .importing(count: nil) }   // fetch resolved

        // By the time we observe it, the state is either the transient `.importing(count: 3)` or
        // (the fast local insert loop having already finished) `.done(count: 3)` — both prove the
        // real fetched count made it into the state rather than staying frozen at 0.
        switch vm.contacts {
        case .importing(let count): #expect(count == 3)
        case .done(let count): #expect(count == 3)
        default: Issue.record("expected .importing(count: 3) or .done(count: 3), got \(vm.contacts)")
        }
        await task.value
        #expect(vm.contacts == .done(count: 3))
    }

    /// F5: `handleContactsChange` must snap the toggle back off on a revoked permission exactly like
    /// `load()` does — previously it only updated `contacts`, leaving the switch on over an amber row.
    @Test("F5: a Contacts change notification that finds permission revoked snaps the toggle back off")
    func contactsChangeSnapsBackOnRevoke() async throws {
        let h = Harness()
        let contacts = FakeContacts(authorization: .granted, names: ["Anh Nguyen"])
        let vm = h.vm(contacts: contacts)
        await vm.load()
        await vm.setLearnFromContacts(true)
        #expect(h.settings.learnFromContacts == true)

        contacts.setAuthorization(.denied)
        contacts.fireChange()

        await waitFor { vm.contacts == .denied }
        #expect(h.settings.learnFromContacts == false)
    }

    /// F7: a toggle-off that lands while an "on" import is still fetching must win — once the stale
    /// import's fetch finally resolves, its result is discarded and any rows it wrote are removed,
    /// rather than clobbering the "off" state with a stale `.done`.
    @Test("F7: toggling off during an in-flight import cancels it and leaves no contacts rows behind")
    func toggleOffDuringImportWins() async throws {
        let h = Harness()
        let blocking = BlockingFakeContacts(names: ["Anh Nguyen", "Priya Raghunathan"])
        let vm = h.vm(contacts: blocking)
        await vm.load()

        let onTask = Task { await vm.setLearnFromContacts(true) }
        await waitFor { vm.contacts == .importing(count: nil) }

        await vm.setLearnFromContacts(false)   // arrives while the fetch above is still blocked
        #expect(vm.contacts == .off)
        #expect(h.settings.learnFromContacts == false)

        blocking.unblock()   // the stale "on" import can now finish...
        await onTask.value    // ...and settle

        // The stale import must not have resurrected the toggle or left any contacts rows behind.
        #expect(vm.contacts == .off)
        #expect(h.settings.learnFromContacts == false)
        #expect(vm.entries.isEmpty)
        let stored = await h.content.dictionary.all()
        #expect(stored.isEmpty)
    }

    @Test("openContactsSettings opens the Contacts privacy pane")
    func opensContactsSettings() {
        let h = Harness()
        var opened: [URL] = []
        let vm = DictionaryViewModel(content: h.content, contactsImporter: FakeContacts(), stylingSettings: h.settings,
                                     openURL: { opened.append($0) })

        vm.openContactsSettings()

        #expect(opened == [URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")!])
    }

    @Test("isEmpty reflects whether there are any dictionary entries")
    func isEmptyReflectsEntries() async throws {
        let h = Harness()
        let vm = h.vm()
        await vm.load()
        #expect(vm.isEmpty == true)

        vm.presentAdd()
        vm.sheet?.word = "Kubernetes"
        await vm.add()

        #expect(vm.isEmpty == false)
    }
}
