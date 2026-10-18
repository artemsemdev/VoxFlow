import Foundation
import Testing
import VoxFlowCore
import VoxFlowDictation
import VoxFlowStorage
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("HistoryWriter")
struct HistoryWriterTests {
    let result = DictationResult(text: "hello there", rawText: "hello there", segments: [],
                                 language: LanguageDetection(code: "en", confidence: 0.9), duration: 2.5, lowConfidence: false)

    @Test("draft mapping: language code, no style, duration and time carried over")
    func draft() {
        let d = HistoryWriter.draft(from: result, appName: "Mail", now: Date(timeIntervalSince1970: 42))
        #expect(d == DictationDraft(text: "hello there", rawText: "hello there", appName: "Mail", style: nil, language: "en", duration: 2.5,
                                    createdAt: Date(timeIntervalSince1970: 42)))
    }

    @Test("draft mapping carries the resolved style through")
    func draftCarriesStyle() {
        let styled = DictationResult(text: "hello there", rawText: "hello there", segments: [],
                                     language: LanguageDetection(code: "en", confidence: 0.9), duration: 2.5, lowConfidence: false,
                                     style: "formal")
        let d = HistoryWriter.draft(from: styled, appName: "Mail", now: Date(timeIntervalSince1970: 42))
        #expect(d.style == "formal")
    }

    @Test("draft mapping carries only validated raw annotations")
    func draftCarriesAnnotations() {
        let span = RawTextSpan(location: 0, length: 5)!
        let annotations = DictationAnnotations(wordConfidences: [WordConfidence(span: span, confidence: 0.78)!])
        let annotated = DictationResult(text: "hello there", rawText: "hello there", segments: [], language: nil,
                                       duration: 1, lowConfidence: false, annotations: annotations)
        #expect(HistoryWriter.draft(from: annotated, appName: nil, now: Date()).annotations == annotations)
    }

    @Test("saves when keepHistory is on; skips when off")
    func save() async throws {
        let store = try DictationStore(inMemoryWith: nil)
        let storeBox = HistoryStoreBox(store)
        let on = DictationSettingsBox(DictationSettingsSnapshot(excludedBundleIDs: [], keepHistory: true, options: TranscriptionOptions()))
        await HistoryWriter(storeBox: storeBox, settings: on, now: { Date() }).save(result, appName: "Mail")
        #expect(try store.count() == 1)
        let off = DictationSettingsBox(DictationSettingsSnapshot(excludedBundleIDs: [], keepHistory: false, options: TranscriptionOptions()))
        await HistoryWriter(storeBox: storeBox, settings: off, now: { Date() }).save(result, appName: "Mail")
        #expect(try store.count() == 1)
    }

    @Test("skips when the store box has no store (history unavailable)")
    func skipsWithoutStore() async throws {
        let storeBox = HistoryStoreBox(nil)
        let on = DictationSettingsBox(DictationSettingsSnapshot(excludedBundleIDs: [], keepHistory: true, options: TranscriptionOptions()))
        await HistoryWriter(storeBox: storeBox, settings: on, now: { Date() }).save(result, appName: "Mail")
        // Nothing to assert on directly (no store to query) — this just must not crash or hang.
    }

    @Test("save awaits the ready closure before reading the store — a still-opening service doesn't drop the write")
    func saveWaitsForReady() async throws {
        let store = try DictationStore(inMemoryWith: nil)
        let storeBox = HistoryStoreBox(store)
        let settings = DictationSettingsBox(DictationSettingsSnapshot(excludedBundleIDs: [], keepHistory: true, options: TranscriptionOptions()))
        let gate = Gate()
        let writer = HistoryWriter(storeBox: storeBox, settings: settings, now: { Date() }, ready: { await gate.wait() })

        let saveTask = Task { await writer.save(result, appName: "Mail") }
        await Task.yield()
        #expect(try store.count() == 0)          // parked on `ready()`: not inserted yet

        await gate.open()
        await saveTask.value
        #expect(try store.count() == 1)          // inserted exactly once, after the gate opened
    }

    @Test("onSaved fires exactly once after a successful insert; never when the save is skipped (C1)")
    func onSavedFiresOnlyAfterASuccessfulInsert() async throws {
        let store = try DictationStore(inMemoryWith: nil)
        let storeBox = HistoryStoreBox(store)
        let calls = OnSavedCounter()

        let on = DictationSettingsBox(DictationSettingsSnapshot(excludedBundleIDs: [], keepHistory: true, options: TranscriptionOptions()))
        await HistoryWriter(storeBox: storeBox, settings: on, now: { Date() }, onSaved: { await calls.increment() })
            .save(result, appName: "Mail")
        #expect(try store.count() == 1)
        #expect(await calls.count == 1)

        // keepHistory off: `save` returns before ever reading the store — `onSaved` must not fire.
        let off = DictationSettingsBox(DictationSettingsSnapshot(excludedBundleIDs: [], keepHistory: false, options: TranscriptionOptions()))
        await HistoryWriter(storeBox: storeBox, settings: off, now: { Date() }, onSaved: { await calls.increment() })
            .save(result, appName: "Mail")
        #expect(try store.count() == 1)
        #expect(await calls.count == 1)

        // No store at all (history unavailable): still no `onSaved`.
        let emptyBox = HistoryStoreBox(nil)
        await HistoryWriter(storeBox: emptyBox, settings: on, now: { Date() }, onSaved: { await calls.increment() })
            .save(result, appName: "Mail")
        #expect(await calls.count == 1)
    }
}

/// A `Sendable` call counter for `onSaved`'s `@Sendable async -> Void` closure — an `actor` rather
/// than a `Mutex`-boxed class since nothing here needs synchronous access.
private actor OnSavedCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
