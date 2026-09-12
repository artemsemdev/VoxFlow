import AppKit
import CryptoKit
import Foundation
import SwiftUI
import Testing
import VoxFlowCore
import VoxFlowStorage
import VoxFlowTestSupport
@testable import VoxFlow

private struct AnnotationHistoryKeyProvider: HistoryKeyProviding {
    let key = SymmetricKey(size: .bits256)
    func historyKey() throws -> HistoryKey { HistoryKey(key: key, isNewlyCreated: false) }
}

@Suite("History annotation presentation") @MainActor
struct HistoryAnnotationTests {
    private func span(of word: String, in text: String) -> RawTextSpan {
        let range = (text as NSString).range(of: word)
        return RawTextSpan(location: range.location, length: range.length)!
    }

    private func record(rawText: String, text: String = "Styled text",
                        annotations: DictationAnnotations? = nil, unreadable: Bool = false) -> DictationRecord {
        DictationRecord(id: 1, text: text, rawText: rawText, appName: "Slack", style: "veryCasual",
                        language: "en", duration: 9, words: 5, createdAt: Date(),
                        isUnreadable: unreadable, annotations: annotations)
    }

    @Test("UTF-16 spans decorate only raw fillers and low-confidence words")
    func unicodeRawPresentation() {
        let raw = "🙂 um send finânce now"
        let filler = span(of: "um", in: raw)
        let low = span(of: "finânce", in: raw)
        let threshold = span(of: "send", in: raw)
        let annotations = DictationAnnotations(removedFillerSpans: [filler], wordConfidences: [
            WordConfidence(span: low, confidence: 0.78)!,
            WordConfidence(span: threshold, confidence: 0.80)!,
        ])

        let presentation = HistoryAnnotationPresentation(record: record(rawText: raw, annotations: annotations))

        #expect(presentation.rawText == raw)
        #expect(presentation.decorations == [
            .init(span: filler, kind: .removedFiller),
            .init(span: low, kind: .lowConfidence(0.78)),
        ])
        #expect(presentation.badges == ["1 filler removed", "1 word 78% confident"])
    }

    @Test("multiple low-confidence words show their real rounded average")
    func averageConfidence() {
        let raw = "alpha beta gamma"
        let annotations = DictationAnnotations(wordConfidences: [
            WordConfidence(span: span(of: "alpha", in: raw), confidence: 0.61)!,
            WordConfidence(span: span(of: "beta", in: raw), confidence: 0.749)!,
            WordConfidence(span: span(of: "gamma", in: raw), confidence: 0.95)!,
        ])
        let presentation = HistoryAnnotationPresentation(record: record(rawText: raw, annotations: annotations))
        #expect(presentation.badges == ["2 words 68% average confidence"])
    }

    @Test("old, malformed and unreadable rows omit annotation UI")
    func omittedMetadata() {
        let raw = "um hello"
        let valid = DictationAnnotations(removedFillerSpans: [span(of: "um", in: raw)])
        let invalid = DictationAnnotations(removedFillerSpans: [RawTextSpan(location: 80, length: 2)!])
        #expect(HistoryAnnotationPresentation(record: record(rawText: raw)).decorations.isEmpty)
        #expect(HistoryAnnotationPresentation(record: record(rawText: raw, annotations: invalid)).badges.isEmpty)
        #expect(HistoryAnnotationPresentation(record: record(rawText: raw, annotations: valid,
                                                              unreadable: true)).decorations.isEmpty)
    }

    @Test("annotations stay anchored to raw text after inserted text is edited")
    func editedInsertedText() {
        let raw = "um original phrase"
        let filler = span(of: "um", in: raw)
        let presentation = HistoryAnnotationPresentation(record: record(
            rawText: raw, text: "A completely rewritten inserted sentence.",
            annotations: DictationAnnotations(removedFillerSpans: [filler])))
        #expect(presentation.rawText == raw)
        #expect(presentation.decorations.map(\.span) == [filler])
    }
}

@Suite("History annotation renders",
       .enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_RENDER"] != nil))
@MainActor
struct HistoryAnnotationRenderTests {
    @Test("renders known and unavailable annotations in both appearances",
          arguments: ["known", "unknown"], [false, true])
    func render(state: String, dark: Bool) throws {
        let raw = "um so can we uh push the meeting to like Thursday — I mean finance first"
        let annotations: DictationAnnotations? = state == "known" ? DictationAnnotations(
            removedFillerSpans: ["um so", "uh", "like", "I mean"].map { span(of: $0, in: raw) },
            wordConfidences: [WordConfidence(span: span(of: "finance", in: raw), confidence: 0.78)!]
        ) : nil
        let record = DictationRecord(id: 1,
            text: "Can we push the meeting to Thursday? I need the numbers from finance first.",
            rawText: raw, appName: "Slack", style: "veryCasual", language: "en",
            duration: 9, words: 15, createdAt: Date(), annotations: annotations)
        let directory = TemporaryDirectory()
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        let history = HistoryService(directory: directory, settings: settings,
            keyProvider: { AnnotationHistoryKeyProvider() }, clock: SystemMonotonicClock())
        let model = HistoryViewModel(service: history, settings: settings, navigation: Navigation(),
                                     clock: SystemMonotonicClock())
        let content = HistoryDetailView(record: record, model: model)
            .frame(width: 860, height: 250)
            .background(dark ? Color(white: 0.1) : .white)
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 250),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.appearance = window.appearance
        window.contentView = host
        defer { window.close() }
        host.frame = window.contentView!.bounds
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".superpowers/design/renders")
            .appendingPathComponent("History-annotations-\(state)-\(dark ? "dark" : "light").png")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try png.write(to: output)
    }

    private func span(of word: String, in text: String) -> RawTextSpan {
        let range = (text as NSString).range(of: word)
        return RawTextSpan(location: range.location, length: range.length)!
    }
}
