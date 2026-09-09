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

        func vm(contacts: FakeContacts = FakeContacts()) -> DictionaryViewModel {
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

        guard case .duplicate(let existing) = vm.validation else {
            Issue.record("expected .duplicate, got \(String(describing: vm.validation))")
            return
        }
        #expect(existing.word == "Kubernetes")
        #expect(vm.canAdd == false)
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
