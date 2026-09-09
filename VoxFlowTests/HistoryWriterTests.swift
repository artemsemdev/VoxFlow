import Foundation
import Testing
import VoxFlowCore
import VoxFlowDictation
import VoxFlowStorage
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
}
