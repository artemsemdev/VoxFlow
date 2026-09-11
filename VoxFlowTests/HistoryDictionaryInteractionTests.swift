import CryptoKit
import Foundation
import SwiftUI
import Testing
import VoxFlowCore
import VoxFlowStorage
import VoxFlowTestSupport
@testable import VoxFlow

private struct HistoryDictionaryKeyProvider: HistoryKeyProviding {
    let key = SymmetricKey(size: .bits256)
    func historyKey() throws -> HistoryKey { HistoryKey(key: key, isNewlyCreated: false) }
}

@Suite("History dictionary interaction") @MainActor
struct HistoryDictionaryInteractionTests {
    @Test("right-click offset identifies the word without relying on selection")
    func wordAtOffset() {
        let text = "Send Acmé's invoice, today."
        #expect(TranscriptWordPicker.word(atUTF16Offset: 7, in: text) == "Acmé's")
        #expect(TranscriptWordPicker.word(atUTF16Offset: 21, in: text) == "today")
        #expect(TranscriptWordPicker.word(atUTF16Offset: 4, in: text) == nil)
    }

    @Test("native context menu targets the clicked word and preserves text selection")
    func nativeContextMenu() throws {
        let text = "Keep selected text; add Quokka instead."
        let view = ContextWordTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 80))
        view.isEditable = false
        view.isSelectable = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.string = text
        view.font = .systemFont(ofSize: 13)
        view.textContainer?.containerSize = NSSize(width: 360, height: CGFloat.greatestFiniteMagnitude)
        let textContainer = try #require(view.textContainer)
        view.layoutManager?.ensureLayout(for: textContainer)
        let wordRange = try #require(text.range(of: "Quokka"))
        let character = NSRange(wordRange, in: text).location + 2
        let glyph = try #require(view.layoutManager?.glyphIndexForCharacter(at: character))
        let rect = try #require(view.layoutManager?.boundingRect(
            forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer))
            .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        let selection = NSRange(location: 0, length: 4)
        view.setSelectedRange(selection)
        var added: String?
        view.addToDictionary = { added = $0 }
        let nativeMenu = NSMenu()
        nativeMenu.addItem(withTitle: "Copy", action: nil, keyEquivalent: "")

        let menu = view.contextMenu(at: NSPoint(x: rect.midX, y: rect.midY), addingTo: nativeMenu)
        #expect(menu.item(withTitle: "Copy") != nil)
        let addItem = try #require(menu.item(withTitle: "Add to Dictionary"))
        #expect(addItem.target === view)
        #expect(addItem.action == #selector(ContextWordTextView.addClickedWord))
        view.addClickedWord()
        #expect(added == "Quokka")
        #expect(view.selectedRange() == selection)
    }

    @Test("history add reuses dictionary duplicate rules and leaves the transcript untouched")
    func addAndDuplicate() async throws {
        let directory = TemporaryDirectory()
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        let history = HistoryService(directory: directory, settings: settings,
                                     keyProvider: { HistoryDictionaryKeyProvider() }, clock: SystemMonotonicClock())
        let content = ContentService(history: history)
        let dictionary = DictionaryViewModel(content: content, contactsImporter: FakeContacts(),
            stylingSettings: StylingSettings(store: InMemoryKeyValueStore()), openURL: { _ in })
        _ = await history.count()
        let record = try #require(try history.store?.insert(DictationDraft(
            text: "Send Quokka today", rawText: "raw Quokka transcript", appName: "Mail",
            style: nil, language: "en", duration: 1, createdAt: Date())))

        dictionary.sheet = .init(word: "Pending sheet")
        await dictionary.addFromHistory("Quokka")
        await dictionary.addFromHistory("quókká")

        #expect(await content.dictionary.all().map(\.word) == ["Quokka"])
        #expect(dictionary.sheet?.word == "Pending sheet")
        #expect(await history.fetch(limit: 1).first?.id == record.id)
        #expect(await history.fetch(limit: 1).first?.rawText == "raw Quokka transcript")
    }
}

@Suite("History dictionary render",
       .enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_RENDER"] != nil))
@MainActor
struct HistoryDictionaryRenderTests {
    @Test("renders expanded transcript dictionary guidance in the native text view")
    func expandedCard() throws {
        let directory = TemporaryDirectory()
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        let history = HistoryService(directory: directory, settings: settings,
                                     keyProvider: { HistoryDictionaryKeyProvider() }, clock: SystemMonotonicClock())
        let model = HistoryViewModel(service: history, settings: settings, navigation: Navigation(),
                                     clock: SystemMonotonicClock())
        let record = DictationRecord(id: 1,
            text: "Hi Priya, attaching the signed Quokka NDA. Let me know if legal needs anything else.",
            rawText: "hi priya attaching the signed quokka nda let me know if legal needs anything else",
            appName: "Mail", style: "formal", language: "en", duration: 12, words: 15, createdAt: Date())
        let content = HistoryDetailView(record: record, model: model)
            .frame(width: 860, height: 230)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 230),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        defer { window.close() }
        host.frame = window.contentView!.bounds
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".superpowers/design/renders")
            .appendingPathComponent("History-add-to-dictionary.png")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try png.write(to: output)
    }
}
