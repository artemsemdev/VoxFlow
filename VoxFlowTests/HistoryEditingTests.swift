import Testing
import VoxFlowStorage
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("History editing", .timeLimit(.minutes(1)))
@MainActor
struct HistoryEditingTests {
    @Test("superseding the post-save search cannot make Delete and Undo restore pre-edit text")
    func interruptedSaveRefresh() async throws {
        let h = HistoryViewModelTests.Harness()
        let original = await h.seed(1)[0]
        let gate = FakeClock()
        var holdNextCatalog = false
        let vm = HistoryViewModel(service: h.service, settings: h.settings, navigation: h.navigation,
                                  clock: h.clock, pasteboard: FakePasteboard(), searchRecords: { query in
            let result = await h.service.search(query)
            if query.isEmpty, holdNextCatalog {
                holdNextCatalog = false
                try? await gate.sleep(for: 1)
            }
            return result
        })
        await vm.load()
        vm.beginEditing(original)
        vm.editedText = "Corrected text"
        holdNextCatalog = true
        let save = Task { await vm.saveEdit() }
        await gate.waitForSleepers(1)
        vm.query = "dictation"
        await h.clock.waitForSleepers(1)
        await gate.advance(by: 1)
        await save.value
        #expect(vm.records.first?.text == "Corrected text")
        vm.delete(try #require(vm.records.first))
        await vm.refresh()
        vm.undo()
        for _ in 0..<2_000 where (try? h.service.store?.count()) == 0 { await Task.yield() }
        #expect(await h.service.fetch(limit: 1).first?.text == "Corrected text")
    }

    @Test("a draft pinned outside text search can be deleted and undone without widening filters")
    func deletePinnedDraft() async {
        let h = HistoryViewModelTests.Harness()
        let original = await h.seed(1)[0]
        let vm = h.vm()
        await vm.load()
        vm.beginEditing(original)
        vm.query = "unmatched search"
        await vm.refresh()
        #expect(vm.records.map(\.id) == [original.id])
        vm.delete(original)
        await vm.refresh()
        #expect(vm.editingID == nil)
        #expect(await h.service.count() == 0)
        #expect(vm.records.isEmpty)
        vm.undo()
        for _ in 0..<2_000 where (try? h.service.store?.count()) == 0 { await Task.yield() }
        await vm.refresh()
        #expect(await h.service.count() == 1)
        #expect(vm.records.isEmpty)
        #expect(vm.query == "unmatched search")
    }

    @Test("app and date filtering keep an open draft reachable until Cancel", arguments: [false, true])
    func filtersKeepDraft(dateFilter: Bool) async {
        let h = HistoryViewModelTests.Harness()
        let original = await h.seed(1)[0]
        let vm = h.vm()
        await vm.load()
        vm.beginEditing(original)
        vm.editedText = "Keep this correction"
        if dateFilter { vm.dateRange = .today } else { vm.selectedApp = "Mail" }
        #expect(vm.records.contains(where: { $0.id == original.id }))
        #expect(vm.expandedID == original.id)
        await vm.refresh()
        #expect(vm.records.contains(where: { $0.id == original.id }))
        #expect(vm.editedText == "Keep this correction")
        vm.cancelEdit()
        await vm.refresh()
        #expect(vm.records.isEmpty)
        #expect(vm.editingID == nil)
        #expect(vm.dateRange == (dateFilter ? .today : .allTime))
        #expect(vm.selectedApp == (dateFilter ? nil : "Mail"))
    }

    @Test("Save updates the stored text, rows and statistics while preserving the raw transcript")
    func save() async throws {
        let h = HistoryViewModelTests.Harness()
        let original = await h.seed(1)[0]
        let vm = h.vm()
        await vm.load()
        var notifications = 0
        h.service.onChange = { notifications += 1 }
        vm.beginEditing(original)
        #expect(vm.editingID == original.id)
        #expect(vm.editedText == original.text)
        #expect(!vm.canSaveEdit)
        vm.editedText = "Corrected text"
        #expect(vm.canSaveEdit)
        await vm.saveEdit()
        let stored = try #require(await h.service.fetch(limit: 1).first)
        #expect(stored.text == "Corrected text")
        #expect(stored.words == 2)
        #expect(stored.rawText == original.rawText)
        #expect(stored.style == original.style)
        #expect(vm.records.first == stored)
        #expect(vm.editingID == nil)
        #expect(notifications == 1)
    }

    @Test("Cancel discards only the draft; unreadable rows cannot enter edit mode")
    func cancelAndUnreadable() async throws {
        let h = HistoryViewModelTests.Harness()
        let original = await h.seed(1)[0]
        let vm = h.vm()
        await vm.load()
        vm.beginEditing(original)
        vm.editedText = "Discard this"
        vm.cancelEdit()
        #expect(vm.editingID == nil)
        #expect(vm.editedText.isEmpty)
        #expect(await h.service.fetch(limit: 1).first == original)
        var unreadable = original
        unreadable.isUnreadable = true
        vm.beginEditing(unreadable)
        #expect(vm.editingID == nil)
    }

    @Test("failed persistence retains the draft and offers retry")
    func failure() async {
        let h = HistoryViewModelTests.Harness()
        let original = await h.seed(1)[0]
        let vm = HistoryViewModel(service: h.service, settings: h.settings, navigation: h.navigation,
                                  clock: h.clock, pasteboard: FakePasteboard(), updateText: { _, _ in nil })
        await vm.load()
        vm.beginEditing(original)
        vm.editedText = "Keep my correction"
        await vm.saveEdit()
        #expect(vm.editingID == original.id)
        #expect(vm.editedText == "Keep my correction")
        #expect(vm.editError != nil)
        #expect(vm.canSaveEdit)
        #expect(await h.service.fetch(limit: 1).first == original)
    }

    @Test("Re-style cannot overwrite a row while an edit is open")
    func excludesRestyling() async {
        let h = HistoryViewModelTests.Harness()
        let original = await h.seed(1)[0]
        let vm = h.vm()
        await vm.load()
        vm.beginEditing(original)
        await vm.restyle(original, to: .formal)
        #expect(await h.service.fetch(limit: 1).first == original)
    }

    @Test("saving is single-flight and cannot be cancelled, replaced or deleted while writing")
    func savingGate() async {
        let h = HistoryViewModelTests.Harness()
        let originals = await h.seed(2)
        let gate = FakeClock()
        var writes = 0
        let vm = HistoryViewModel(service: h.service, settings: h.settings, navigation: h.navigation,
                                  clock: h.clock, pasteboard: FakePasteboard(), updateText: { id, text in
            writes += 1
            try? await gate.sleep(for: 1)
            return await h.service.updateText(id: id, text: text)
        })
        await vm.load()
        vm.beginEditing(originals[0])
        vm.editedText = "Correction"
        let first = Task { await vm.saveEdit() }
        await gate.waitForSleepers(1)
        #expect(vm.isSavingEdit)
        #expect(!vm.canSaveEdit)
        vm.cancelEdit()
        vm.beginEditing(originals[1])
        vm.delete(originals[0])
        #expect(vm.editingID == originals[0].id)
        #expect(vm.records.count == 2)
        let second = Task { await vm.saveEdit() }
        for _ in 0..<2_000 where writes == 1 { await Task.yield() }
        #expect(writes == 1)
        await gate.waitForSleepers(writes)
        await gate.advance(by: 1)
        await first.value
        await second.value
        #expect(!vm.isSavingEdit)
        #expect(vm.editingID == nil)
    }

    @Test("switching rows cannot discard an open draft before Save or Cancel")
    func keepsDraft() async {
        let h = HistoryViewModelTests.Harness()
        let originals = await h.seed(2)
        let vm = h.vm()
        await vm.load()
        vm.beginEditing(originals[0])
        vm.editedText = "Keep this draft"
        vm.toggleExpanded(id: originals[1].id)
        vm.beginEditing(originals[1])
        #expect(vm.expandedID == originals[0].id)
        #expect(vm.editingID == originals[0].id)
        #expect(vm.editedText == "Keep this draft")
    }

    @Test("refresh preserves filtered-out drafts but reconciles a genuinely deleted row")
    func reconcilesDeletedRow() async {
        let h = HistoryViewModelTests.Harness()
        let original = await h.seed(1)[0]
        let vm = h.vm()
        await vm.load()
        vm.beginEditing(original)
        vm.editedText = "Keep this draft"
        vm.query = "no matching record"
        await vm.refresh()
        #expect(vm.editingID == original.id)
        #expect(vm.editedText == "Keep this draft")
        #expect(vm.records.contains(where: { $0.id == original.id }))
        #expect(vm.expandedID == original.id)
        await h.service.deleteAll()
        await vm.refresh()
        #expect(vm.editingID == nil)
        #expect(vm.canEdit(original))
    }
}
