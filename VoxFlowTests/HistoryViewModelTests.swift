import CryptoKit
import Foundation
import Testing
import VoxFlowCore
import VoxFlowDictation
import VoxFlowStorage
import VoxFlowStyling
import VoxFlowTestSupport
@testable import VoxFlow

/// A real (fake, in-memory) key provider rather than a `fatalError`-ing stub: `HistoryService` opens
/// lazily on first access, so whether `encryptHistory` is true or false at the moment that happens
/// depends on ordering a test doesn't control (e.g. a test that flips `encryptHistory` after
/// constructing the harness, before ever touching the service). A stub that traps if ever called was
/// latent breakage waiting for exactly that ordering.
private struct FakeHistoryKeyProvider: HistoryKeyProviding {
    let key = SymmetricKey(size: .bits256)
    func historyKey() throws -> HistoryKey { HistoryKey(key: key, isNewlyCreated: false) }
}

/// I-4: claims `isNewlyCreated: true` on every call (unlike `FakeHistoryKeyProvider` above) — opening
/// an *already-encrypted* database with this is exactly what `DictationStore` treats as "the original
/// key is gone" (`StorageError.keyLost`, mirroring `HistoryServiceTests.keyLostDisablesHistory`).
private struct FakeFreshKeyProvider: HistoryKeyProviding {
    func historyKey() throws -> HistoryKey { HistoryKey(key: SymmetricKey(size: .bits256), isNewlyCreated: true) }
}

@Suite("HistoryViewModel", .timeLimit(.minutes(1)))
@MainActor
struct HistoryViewModelTests {
    static func makeService(dir: TemporaryDirectory, settings: DictationSettings, clock: any MonotonicClock) -> HistoryService {
        HistoryService(url: dir.file("voxflow.sqlite"), settings: settings,
                       keyProvider: { FakeHistoryKeyProvider() }, clock: clock)
    }

    static func draft(_ text: String, appName: String = "Slack", style: String? = "veryCasual", language: String? = "en",
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
            settings.retentionDays = 0   // seeded rows use epoch dates; keep the live retention purge out of the way
            settings.keepHistory = keepHistory
            // Retention's daily sleeper must never satisfy the view model's debounce/Undo gates.
            service = HistoryViewModelTests.makeService(dir: dir, settings: settings, clock: FakeClock())
        }

        /// `restyler` is nil-able (not defaulted to a real `Restyler`) so passing nothing here keeps
        /// exercising `HistoryViewModel.init`'s own default, the same one production leaves unused
        /// (`AppServices` always passes the real `services.restyler`).
        func vm(pasteboard: any Pasteboard = FakePasteboard(), restyler: Restyler? = nil) -> HistoryViewModel {
            if let restyler {
                let model = HistoryViewModel(service: service, settings: settings, navigation: navigation, clock: clock,
                                        pasteboard: pasteboard, restyler: restyler)
                model.dateRange = .allTime
                return model
            }
            let model = HistoryViewModel(service: service, settings: settings, navigation: navigation, clock: clock, pasteboard: pasteboard)
            model.dateRange = .allTime // These existing tests use retained epoch fixtures, independent of date filtering.
            return model
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
        let record = DictationRecord(id: 1, text: "hi", rawText: "hi", appName: "Slack", style: "veryCasual",
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

        let sleepersBefore = h.clock.sleeperCount
        vm.query = "num"
        // Not yet applied — the debounce hasn't elapsed.
        #expect(vm.records.count == 2)

        await h.clock.waitForSleepers(sleepersBefore + 1)   // the debounce task's `clock.sleep(for: 0.15)` registering
        await h.clock.advance(by: 0.15)
        await waitFor { vm.records.count == 1 }

        #expect(vm.records.map(\.text) == ["call about quarterly numbers"])
    }

    @Test("M1: clearSearch bypasses the 150 ms debounce — no clock advance needed for the list to return")
    func clearSearchIsImmediate() async throws {
        let h = Harness()
        await h.seed(0)   // forces the store open before `.store!` below
        _ = try! h.service.store!.insert(HistoryViewModelTests.draft("call about quarterly numbers", at: Date(timeIntervalSince1970: 1)))
        let vm = h.vm()
        await vm.load()

        vm.query = "no match for this"
        let sleepersBefore = h.clock.sleeperCount
        await h.clock.waitForSleepers(sleepersBefore + 1)
        await h.clock.advance(by: 0.15)
        await waitFor { vm.records.isEmpty }
        #expect(vm.emptyState == .noResults("no match for this"))

        vm.clearSearch()
        // No `clock.advance` here — an empty query must skip the debounce entirely (M1); if it didn't,
        // `records` would stay empty for 150 ms and `emptyState` would flash `.noDictations`.
        await waitFor { !vm.records.isEmpty }
        #expect(vm.emptyState == nil)
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

        let sleepersBefore = h.clock.sleeperCount
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

        let sleepersBefore = h.clock.sleeperCount
        vm.query = "nothing matches this"
        await h.clock.waitForSleepers(sleepersBefore + 1)
        await h.clock.advance(by: 0.15)
        await waitFor { vm.records.isEmpty }

        #expect(vm.emptyState == .noResults("nothing matches this"))
    }

    @Test("I-4: emptyState is .unavailable when the history service is disabled — outranks .noDictations, and maps the key-lost reason to readable copy")
    func emptyStateUnavailableWhenHistoryDisabled() async throws {
        let dir = TemporaryDirectory()
        let url = dir.file("voxflow.sqlite")
        // An already-encrypted database on disk (mirrors `HistoryServiceTests.keyLostDisablesHistory`)
        // — `records` will still end up empty (the broken service can't read it), so this also proves
        // `.unavailable` isn't just falling out of the ordinary `.noDictations` path.
        _ = try DictationStore(databaseURL: url, keyProvider: FakeHistoryKeyProvider())
            .insert(HistoryViewModelTests.draft("secret", at: Date()))

        let settings = DictationSettings(store: InMemoryKeyValueStore())
        settings.retentionDays = 0
        let brokenService = HistoryService(url: url, settings: settings, keyProvider: { FakeFreshKeyProvider() }, clock: FakeClock())
        let vm = HistoryViewModel(service: brokenService, settings: settings, navigation: Navigation(), clock: FakeClock())

        await vm.load()

        #expect(vm.records.isEmpty)
        #expect(vm.emptyState == .unavailable(reason: "The history key could not be found in your Keychain"))
        withExtendedLifetime(dir) {}   // the temp dir must outlive the service's open attempt
    }

    @Test("I-4: emptyState does not treat the service's transient not-opened-yet placeholder as unavailable")
    func emptyStateIgnoresNotOpenedYetPlaceholder() {
        let h = Harness()
        let vm = h.vm()
        // Never awaited load()/refresh() — `h.service.status` is still `.disabled(reason: "not opened
        // yet")`, the placeholder every fresh `HistoryService` starts with, not a real failure.
        #expect(vm.emptyState == .noDictations)
    }

    @Test("unreadable rows show the encrypted message instead of their text")
    func unreadableRowText() {
        let record = DictationRecord(id: 1, text: "", rawText: "", appName: "Mail", style: nil, language: nil,
                                     duration: 3, words: 0, createdAt: Date(), isUnreadable: true)

        #expect(HistoryViewModel.displayText(for: record) == "Encrypted — turn on 'Encrypt history at rest' to read")
    }

    @Test("M2: unreadable rows show the encrypted message in the detail's raw-text column too")
    func unreadableRowRawText() {
        let record = DictationRecord(id: 1, text: "", rawText: "", appName: "Mail", style: nil, language: nil,
                                     duration: 3, words: 0, createdAt: Date(), isUnreadable: true)

        #expect(HistoryViewModel.displayRawText(for: record) == "Encrypted — turn on 'Encrypt history at rest' to read")
    }

    @Test("M2: detailHeader includes the uppercased style when present, plain \"INSERTED\" otherwise")
    func detailHeaderVariants() {
        let styled = DictationRecord(id: 1, text: "hi", rawText: "hi", appName: "Mail", style: "veryCasual",
                                     language: "en", duration: 3, words: 4, createdAt: Date())
        let unstyled = DictationRecord(id: 2, text: "hi", rawText: "hi", appName: "Mail", style: nil,
                                       language: "en", duration: 3, words: 4, createdAt: Date())

        #expect(HistoryViewModel.detailHeader(for: styled) == "INSERTED · VERY CASUAL")
        #expect(HistoryViewModel.detailHeader(for: unstyled) == "INSERTED")
    }

    @Test("I1: styleLabel maps every TextStyle rawValue to its display name, and passes through an unrecognized value as-is")
    func styleLabelMapsRawToDisplayName() {
        #expect(HistoryViewModel.styleLabel("formal") == "Formal")
        #expect(HistoryViewModel.styleLabel("casual") == "Casual")
        #expect(HistoryViewModel.styleLabel("veryCasual") == "Very casual")
        #expect(HistoryViewModel.styleLabel("verbatim") == "Verbatim")
        #expect(HistoryViewModel.styleLabel("somethingUnknown") == "somethingUnknown")
    }

    /// A `Restyler` backed by `backend` with the same toggle defaults `RestylerTests.box()` uses
    /// (fillers removed, auto-punctuate on) — enough for these tests, which only care whether the
    /// LLM or the rule fallback answered.
    private static func restyler(backend: FakeLLMBackend) -> Restyler {
        Restyler(styler: LlamaStyler(backend: backend, clock: FakeClock()),
                settings: StylingSettingsBox(StylingSettingsSnapshot(defaultStyle: .casual, removeFillers: true,
                                                                     autoPunctuate: true, snippetSayPrefix: false)))
    }

    @Test("restyle updates the row's text/style, copies the result, and clears restylingID")
    func restyleUpdatesRowAndCopies() async throws {
        let h = Harness()
        await h.seed(1)
        let pasteboard = FakePasteboard()
        let backend = FakeLLMBackend(reply: "Could we move it?")
        let vm = h.vm(pasteboard: pasteboard, restyler: HistoryViewModelTests.restyler(backend: backend))
        await vm.load()
        let record = vm.records[0]

        await vm.restyle(record, to: .formal)

        let updated = vm.records.first { $0.id == record.id }
        #expect(updated?.text == "Could we move it?")
        #expect(updated?.style == "formal")
        #expect(pasteboard.strings.last == "Could we move it?")
        #expect(vm.restylingID == nil)
    }

    @Test("restyle falls back to the rule styler when the LLM backend is not ready")
    func restyleFallsBackToRulesWhenNotReady() async throws {
        let h = Harness()
        await h.seed(1)
        let backend = FakeLLMBackend(ready: false, reply: "should never be seen")
        let vm = h.vm(restyler: HistoryViewModelTests.restyler(backend: backend))
        await vm.load()
        let record = vm.records[0]

        await vm.restyle(record, to: .formal)

        let expected = RuleStyler().styleSync(record.rawText, options: StylingOptions(style: .formal, removeFillers: true, autoPunctuate: true)).text
        let updated = vm.records.first { $0.id == record.id }
        #expect(updated?.text == expected)
        #expect(await backend.prompts.isEmpty)
    }

    @Test("restyle is a no-op on an unreadable row")
    func restyleIgnoresUnreadableRows() async throws {
        let h = Harness()
        let vm = h.vm()
        let record = DictationRecord(id: 1, text: "", rawText: "", appName: "Mail", style: nil, language: nil,
                                     duration: 3, words: 0, createdAt: Date(), isUnreadable: true)

        await vm.restyle(record, to: .formal)

        #expect(vm.restylingID == nil)
    }

    @Test("restyle is single-flight: a second call while one is in flight is ignored until the first finishes")
    func restyleIsSingleFlight() async throws {
        let h = Harness()
        await h.seed(1)
        let backend = FakeLLMBackend(reply: "styled")
        await backend.set(hangs: true)
        let vm = h.vm(restyler: HistoryViewModelTests.restyler(backend: backend))
        await vm.load()
        let record = vm.records[0]

        let first = Task { await vm.restyle(record, to: .formal) }
        await waitFor { vm.restylingID != nil }

        await vm.restyle(record, to: .casual)   // guard trips on restylingID != nil — returns immediately
        #expect(vm.restylingID == record.id)     // still the first call's in-flight id

        await backend.release()
        await first.value

        #expect(vm.restylingID == nil)
        #expect(await backend.prompts.count == 1)
    }

    @Test("currentStyle defaults to .casual for a nil or unrecognized style, and reads a known one back")
    func currentStyleDefaultsToCasual() {
        let nilStyle = DictationRecord(id: 1, text: "hi", rawText: "hi", appName: "Mail", style: nil, language: nil,
                                       duration: 3, words: 2, createdAt: Date())
        let unknown = DictationRecord(id: 2, text: "hi", rawText: "hi", appName: "Mail", style: "somethingUnknown",
                                      language: nil, duration: 3, words: 2, createdAt: Date())
        let known = DictationRecord(id: 3, text: "hi", rawText: "hi", appName: "Mail", style: "formal", language: nil,
                                    duration: 3, words: 2, createdAt: Date())

        #expect(HistoryViewModel.currentStyle(of: nilStyle) == .casual)
        #expect(HistoryViewModel.currentStyle(of: unknown) == .casual)
        #expect(HistoryViewModel.currentStyle(of: known) == .formal)
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

    @Test("M9: refresh() re-applies an active query instead of clobbering it with the unfiltered list")
    func refreshRespectsActiveQuery() async throws {
        let h = Harness()
        await h.seed(0)   // forces the store open before `.store!` below
        _ = try! h.service.store!.insert(HistoryViewModelTests.draft("call about quarterly numbers", at: Date(timeIntervalSince1970: 1)))
        _ = try! h.service.store!.insert(HistoryViewModelTests.draft("unrelated grocery list", at: Date(timeIntervalSince1970: 2)))
        let vm = h.vm()
        await vm.load()

        vm.query = "num"
        let sleepersBefore = h.clock.sleeperCount
        await h.clock.waitForSleepers(sleepersBefore + 1)
        await h.clock.advance(by: 0.15)
        await waitFor { vm.records.count == 1 }

        // Simulates `HistoryPage`'s `.task` firing again on a navigation back to History, while the
        // search field still shows "num" — `records` must stay filtered, not revert to both rows.
        await vm.refresh()

        #expect(vm.records.map(\.text) == ["call about quarterly numbers"])
        #expect(vm.query == "num")
    }

    /// Everything the scratchpad-ephemeral tests need: a `DictationCoordinator` wired to `scope` (the
    /// same instance `ScratchpadSheet.onAppear`/`onDisappear` would enter/leave in production) so
    /// `scope.isActive` at capture start is what decides whether the capture reaches
    /// `historyWriter.save` at all (I-1/I-2/I-3).
    private struct ScratchpadBundle {
        let dictation: DictationCoordinator
        let historyWriter: HistoryWriter
        let historyStoreBox: HistoryStoreBox
        let scope: EphemeralScope
        let vm: HistoryViewModel
    }

    private func makeScratchpadBundle(_ h: Harness) throws -> ScratchpadBundle {
        let historyStoreBox = HistoryStoreBox(try DictationStore(inMemoryWith: nil))
        let historyWriter = HistoryWriter(storeBox: historyStoreBox, settings: h.settings.box, now: { Date() })
        let scope = EphemeralScope()
        let transcriber = FakeDictationTranscriber(result: DictationResult(
            text: "one two three", rawText: "one two three", segments: [], language: nil, duration: 0.4, lowConfidence: false))
        let controller = DictationController(
            config: FlowBarConfig(), microphone: FakeMicrophone(), transcriber: transcriber,
            inserter: FakeTextInserter(), clock: h.clock,
            preflight: { Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .loaded) },
            loadModel: {}, options: { TranscriptionOptions() },
            onSave: { result, appName in await historyWriter.save(result, appName: appName) },
            copyToClipboard: { _ in },
            ephemeral: { scope.isActive })
        let permissions = FakePermissions(microphone: .granted, requestResult: .granted, accessibility: true)
        let dictation = DictationCoordinator(controller: controller, settings: h.settings, permissions: permissions, navigation: h.navigation)
        dictation.start()
        let vm = HistoryViewModel(service: h.service, settings: h.settings, navigation: h.navigation, clock: h.clock)
        return ScratchpadBundle(dictation: dictation, historyWriter: historyWriter, historyStoreBox: historyStoreBox, scope: scope, vm: vm)
    }

    @Test("a capture started while the scratchpad scope is active (entered the way ScratchpadSheet.onAppear would) is not saved")
    func scratchpadSuppressesHistory() async throws {
        let h = Harness()
        let bundle = try makeScratchpadBundle(h)
        let dictation = bundle.dictation

        bundle.vm.isScratchpadPresented = true   // mirrors the sheet binding; the scope is what actually matters
        bundle.scope.enter()                     // what ScratchpadSheet.onAppear does
        dictation.fn(.down)
        // `.armed(_)`/`.listening(_)`/`.inserted` (explicit wildcard payload), not `if case .armed = $0`
        // — same toolchain quirk `OnboardingViewModelTests` works around.
        await waitFor { if case .armed(_) = dictation.state { true } else { false } }
        await h.clock.advance(by: 0.3)
        await waitFor { if case .listening(_) = dictation.state { true } else { false } }
        dictation.fn(.up)
        await waitFor { if case .inserted(_, _, _) = dictation.state { true } else { false } }

        #expect(try bundle.historyStoreBox.current?.count() == 0)
    }

    @Test("leaving the scope before the next capture starts (ScratchpadSheet.onDisappear) — that next capture is saved normally, whatever became of the scratchpad one")
    func scratchpadDismissClearsSuppression() async throws {
        let h = Harness()
        let bundle = try makeScratchpadBundle(h)
        let dictation = bundle.dictation

        bundle.vm.isScratchpadPresented = true
        bundle.scope.enter()
        dictation.fn(.down)
        await waitFor { if case .armed(_) = dictation.state { true } else { false } }
        dictation.escape()   // the scratchpad capture itself is discarded, not saved either way
        await waitFor { if case .discarded = dictation.state { true } else { false } }

        bundle.vm.isScratchpadPresented = false   // sheet closed
        bundle.scope.leave()                      // what ScratchpadSheet.onDisappear does
        #expect(bundle.scope.isActive == false)

        await bundle.historyWriter.save(
            DictationResult(text: "a real dictation", rawText: "a real dictation", segments: [], language: nil, duration: 1, lowConfidence: false),
            appName: "Mail")

        #expect(try bundle.historyStoreBox.current?.count() == 1)
    }
}
