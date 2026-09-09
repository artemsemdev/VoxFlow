import Foundation
import Testing
import VoxFlowCore
import VoxFlowDictation
import VoxFlowStorage
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("HistoryViewModel", .timeLimit(.minutes(1)))
@MainActor
struct HistoryViewModelTests {
    /// Encryption off (no key provider needed) so tests don't have to fake `HistoryKeyProviding`.
    static func makeService(dir: TemporaryDirectory, settings: DictationSettings, clock: any MonotonicClock) -> HistoryService {
        settings.encryptHistory = false
        return HistoryService(url: dir.file("voxflow.sqlite"), settings: settings,
                              keyProvider: { fatalError("key provider unused when encryption is off") }, clock: clock)
    }

    static func draft(_ text: String, appName: String = "Slack", style: String? = "Very casual", language: String? = "en",
                      duration: TimeInterval = 9, at date: Date) -> DictationDraft {
        DictationDraft(text: text, rawText: text + " raw", appName: appName, style: style, language: language, duration: duration, createdAt: date)
    }

    @MainActor
    struct Harness {
        let dir = TemporaryDirectory()
        let clock = FakeClock()
        let navigation = Navigation()
        let settings: DictationSettings
        let service: HistoryService

        init(keepHistory: Bool = true) {
            settings = DictationSettings(store: InMemoryKeyValueStore())
            settings.keepHistory = keepHistory
            service = HistoryViewModelTests.makeService(dir: dir, settings: settings, clock: clock)
        }

        func vm(pasteboard: any Pasteboard = FakePasteboard()) -> HistoryViewModel {
            HistoryViewModel(service: service, settings: settings, navigation: navigation, clock: clock, pasteboard: pasteboard)
        }

        @discardableResult
        func seed(_ count: Int) async -> [DictationRecord] {
            _ = await service.count()   // force the open to finish
            var inserted: [DictationRecord] = []
            for i in 0..<count {
                let record = try! service.store!.insert(HistoryViewModelTests.draft("dictation number \(i)", at: Date(timeIntervalSince1970: Double(i))))
                inserted.append(record)
            }
            return inserted
        }
    }

    /// No-sleep poll, same technique as `OnboardingViewModelTests`.
    private func waitFor(_ predicate: () -> Bool) async {
        for _ in 0..<2_000 where !predicate() { await Task.yield() }
    }

    @Test("load lists newest first")
    func loadListsNewestFirst() async throws {
        let h = Harness()
        let inserted = await h.seed(3)
        let vm = h.vm()

        await vm.load()

        #expect(vm.records.map(\.id) == inserted.reversed().map(\.id))
    }

    @Test("metaLine formats app, time, duration, words, style, language")
    func metaLineFormatting() {
        var components = DateComponents()
        components.year = 2026; components.month = 3; components.day = 2; components.hour = 9; components.minute = 26
        let date = Calendar.current.date(from: components)!
        let record = DictationRecord(id: 1, text: "hi", rawText: "hi", appName: "Slack", style: "Very casual",
                                     language: "en", duration: 9, words: 15, createdAt: date)

        #expect(HistoryViewModel.metaLine(for: record) == "Slack · 9:26 AM · 0:09 · 15 words · Very casual · EN")
    }

    @Test("metaLine omits the style clause when there is none")
    func metaLineWithoutStyle() {
        let record = DictationRecord(id: 1, text: "hi", rawText: "hi", appName: "Mail", style: nil,
                                     language: "en", duration: 3, words: 4, createdAt: Date())
        #expect(HistoryViewModel.metaLine(for: record).contains("Very casual") == false)
        #expect(HistoryViewModel.metaLine(for: record).hasSuffix("EN"))
    }

    @Test("search debounces 150 ms before applying a query")
    func searchDebounces() async throws {
        let h = Harness()
        await h.seed(0)
        _ = try! h.service.store!.insert(HistoryViewModelTests.draft("call about quarterly numbers", at: Date(timeIntervalSince1970: 1)))
        _ = try! h.service.store!.insert(HistoryViewModelTests.draft("unrelated grocery list", at: Date(timeIntervalSince1970: 2)))
        let vm = h.vm()
        await vm.load()
        #expect(vm.records.count == 2)

        let sleepersBefore = h.clock.sleeperCount   // the store's RetentionRunner already parks one
        vm.query = "num"
        // Not yet applied — the debounce hasn't elapsed.
        #expect(vm.records.count == 2)

        await h.clock.waitForSleepers(sleepersBefore + 1)   // the debounce task's `clock.sleep(for: 0.15)` registering
        await h.clock.advance(by: 0.15)
        await waitFor { vm.records.count == 1 }

        #expect(vm.records.map(\.text) == ["call about quarterly numbers"])
    }

    @Test("delete removes the row locally, shows the toast, and undo restores it at the same index")
    func deleteThenUndoRestoresPosition() async throws {
        let h = Harness()
        let inserted = await h.seed(3)   // ids ascending 0,1,2 -> newest-first load is [2,1,0]
        let vm = h.vm()
        await vm.load()
        let originalTexts = vm.records.map(\.text)
        let target = vm.records[1]

        vm.delete(target)

        #expect(vm.records.map(\.id).contains(target.id) == false)
        #expect(vm.records.count == 2)
        #expect(vm.toastVisible)
        await waitFor { (try? h.service.store!.count()) == 2 }

        vm.undo()

        await waitFor { vm.records.count == 3 }
        #expect(vm.records.map(\.text) == originalTexts)
        #expect(vm.toastVisible == false)
        #expect(await h.service.count() == 3)
        _ = inserted
    }

    @Test("delete becomes permanent after the 6 s undo window")
    func deleteBecomesPermanentAfterWindow() async throws {
        let h = Harness()
        await h.seed(2)
        let vm = h.vm()
        await vm.load()
        let target = vm.records[0]

        let sleepersBefore = h.clock.sleeperCount   // the store's RetentionRunner already parks one
        vm.delete(target)
        await waitFor { (try? h.service.store!.count()) == 1 }

        await h.clock.waitForSleepers(sleepersBefore + 1)   // the undo timer's `clock.sleep(for: 6)` registering
        await h.clock.advance(by: 6)
        await waitFor { vm.toastVisible == false }

        #expect(await h.service.count() == 1)
        vm.undo()   // a no-op once the window has passed — nothing pending to restore
        await Task.yield()
        #expect(await h.service.count() == 1)
    }

    @Test("emptyState is .noDictations with no rows and no query")
    func emptyStateNoDictations() async throws {
        let h = Harness()
        await h.seed(0)
        let vm = h.vm()
        await vm.load()

        #expect(vm.emptyState == .noDictations)
    }

    @Test("emptyState is .historyOff when keepHistory is false, regardless of rows")
    func emptyStateHistoryOff() async throws {
        let h = Harness(keepHistory: false)
        await h.seed(2)
        let vm = h.vm()
        await vm.load()

        #expect(vm.emptyState == .historyOff)
    }

    @Test("emptyState is .noResults(query) when a search yields nothing")
    func emptyStateNoResults() async throws {
        let h = Harness()
        await h.seed(1)
        let vm = h.vm()
        await vm.load()

        let sleepersBefore = h.clock.sleeperCount   // the store's RetentionRunner already parks one
        vm.query = "nothing matches this"
        await h.clock.waitForSleepers(sleepersBefore + 1)
        await h.clock.advance(by: 0.15)
        await waitFor { vm.records.isEmpty }

        #expect(vm.emptyState == .noResults("nothing matches this"))
    }

    @Test("unreadable rows show the encrypted message instead of their text")
    func unreadableRowText() {
        let record = DictationRecord(id: 1, text: "", rawText: "", appName: "Mail", style: nil, language: nil,
                                     duration: 3, words: 0, createdAt: Date(), isUnreadable: true)

        #expect(HistoryViewModel.displayText(for: record) == "Encrypted — turn on 'Encrypt history at rest' to read")
    }

    @Test("footer text: encrypted on, 30 days")
    func footerEncryptedOn() {
        let h = Harness()
        h.settings.encryptHistory = true
        h.settings.retentionDays = 30
        let vm = h.vm()

        #expect(vm.footerText == "History is encrypted on this Mac and kept for 30 days. Change in Settings → Privacy.")
    }

    @Test("footer text: encryption off, 30 days")
    func footerEncryptedOff() {
        let h = Harness()
        h.settings.encryptHistory = false
        h.settings.retentionDays = 30
        let vm = h.vm()

        #expect(vm.footerText == "History is kept on this Mac for 30 days. Change in Settings → Privacy.")
    }

    @Test("footer text: retention 0 says kept until you delete it")
    func footerRetentionForever() {
        let h = Harness()
        h.settings.encryptHistory = true
        h.settings.retentionDays = 0
        let vm = h.vm()

        #expect(vm.footerText == "History is encrypted on this Mac and kept until you delete it. Change in Settings → Privacy.")
    }

    @Test("copy writes the record's text to the pasteboard")
    func copyWritesToPasteboard() async throws {
        let h = Harness()
        await h.seed(1)
        let pasteboard = FakePasteboard()
        let vm = h.vm(pasteboard: pasteboard)
        await vm.load()

        vm.copy(vm.records[0])

        #expect(pasteboard.strings == [vm.records[0].text])
    }

    @Test("openPrivacySettings navigates to Settings › Privacy")
    func opensPrivacySettings() {
        let h = Harness()
        let vm = h.vm()

        vm.openPrivacySettings()

        #expect(h.navigation.page == .settings)
        #expect(h.navigation.settingsTab == .privacy)
    }

    @Test("toggleExpanded flips the expanded row and back")
    func toggleExpanded() async throws {
        let h = Harness()
        await h.seed(1)
        let vm = h.vm()
        await vm.load()
        let id = vm.records[0].id

        vm.toggleExpanded(id: id)
        #expect(vm.expandedID == id)
        vm.toggleExpanded(id: id)
        #expect(vm.expandedID == nil)
    }

    @Test("entering .armed while the scratchpad sheet is up suppresses the next history save")
    func scratchpadSuppressesHistory() async throws {
        let h = Harness()
        let historyStoreBox = HistoryStoreBox(try DictationStore(inMemoryWith: nil))
        let historyWriter = HistoryWriter(storeBox: historyStoreBox, settings: h.settings.box, now: { Date() })
        let transcriber = FakeDictationTranscriber(result: DictationResult(
            text: "one two three", rawText: "one two three", segments: [], language: nil, duration: 0.4, lowConfidence: false))
        let controller = DictationController(
            config: FlowBarConfig(), microphone: FakeMicrophone(), transcriber: transcriber,
            inserter: FakeTextInserter(), clock: h.clock,
            preflight: { Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .loaded) },
            loadModel: {}, options: { TranscriptionOptions() },
            onSave: { result, appName in await historyWriter.save(result, appName: appName) },
            copyToClipboard: { _ in })
        let permissions = FakePermissions(microphone: .granted, requestResult: .granted, accessibility: true)
        let dictation = DictationCoordinator(controller: controller, settings: h.settings, permissions: permissions, navigation: h.navigation)
        dictation.start()
        let vm = HistoryViewModel(service: h.service, settings: h.settings, navigation: h.navigation, clock: h.clock,
                                  dictation: dictation, historyWriter: historyWriter)

        vm.isScratchpadPresented = true
        dictation.fn(.down)
        // `.armed(_)`/`.listening(_)`/`.inserted` (explicit wildcard payload), not `if case .armed = $0`
        // — same toolchain quirk `OnboardingViewModelTests` works around.
        await waitFor { if case .armed(_) = dictation.state { true } else { false } }
        await h.clock.advance(by: 0.3)
        await waitFor { if case .listening(_) = dictation.state { true } else { false } }
        dictation.fn(.up)
        await waitFor { if case .inserted(_, _, _) = dictation.state { true } else { false } }

        #expect(try historyStoreBox.current?.count() == 0)
    }
}
