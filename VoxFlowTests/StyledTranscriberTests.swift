import Foundation
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowDictation
import VoxFlowStyling
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("StyledTranscriber")
struct StyledTranscriberTests {
    func emptyFeed() -> AsyncStream<AudioChunk> { AsyncStream { $0.finish() } }

    func snapshots(vocabulary: [String] = [], snippets: [SnippetRule] = [], overrides: [String: TextStyle] = [:],
                   noteUses: @escaping @Sendable (String, [String]) -> Void = { _, _ in }) -> ContentSnapshots {
        ContentSnapshots(vocabularyBox: SnapshotBox(vocabulary), snippetsBox: SnapshotBox(snippets),
                         overridesBox: SnapshotBox(overrides), noteUses: noteUses)
    }

    func transcriber(rawText: String, settings: StylingSettingsSnapshot = StylingSettingsSnapshot(defaultStyle: .casual, removeFillers: true, autoPunctuate: true, snippetSayPrefix: false),
                     content: ContentSnapshots? = nil, frontmost: FrontmostApp? = nil, clipboard: String? = nil,
                     now: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> StyledTranscriber {
        let result = DictationResult(text: rawText, rawText: rawText, segments: [], language: nil, duration: 1, lowConfidence: false)
        return StyledTranscriber(base: FakeDictationTranscriber(result: result), styler: RuleStyler(),
                                 settings: StylingSettingsBox(settings), content: content ?? snapshots(),
                                 frontmost: FrontmostBox(frontmost), clipboard: { clipboard }, now: { now })
    }

    @Test("casual default style: fillers removed, sentence capitalized and punctuated")
    func casualDefault() async throws {
        let t = transcriber(rawText: "um so can we push the meeting to thursday")
        let result = try await t.transcribe(emptyFeed(), options: TranscriptionOptions()) { _ in }
        #expect(result.text == "So can we push the meeting to thursday.")
        #expect(result.rawText == "um so can we push the meeting to thursday")
        #expect(result.style == "casual")
        #expect(result.fillersRemoved == 1)
        #expect(result.annotations?.fillersRemoved == 1)
        let span = try #require(result.annotations?.removedFillerSpans?.first)
        #expect(String(result.rawText[try #require(span.range(in: result.rawText))]) == "um")
    }

    @Test("a per-app override for the captured frontmost app wins over the default style")
    func perAppOverride() async throws {
        let content = snapshots(overrides: ["com.apple.mail": .formal])
        let t = transcriber(rawText: "we're gonna push the meeting", content: content,
                            frontmost: FrontmostApp(name: "Mail", bundleID: "com.apple.mail"))
        let result = try await t.transcribe(emptyFeed(), options: TranscriptionOptions()) { _ in }
        #expect(result.style == "formal")
        #expect(result.text == "We are going to push the meeting.")
    }

    @Test("no override for the frontmost app falls back to the default style")
    func noOverrideFallsBackToDefault() async throws {
        let content = snapshots(overrides: ["com.apple.mail": .formal])
        let t = transcriber(rawText: "hello there", content: content,
                            frontmost: FrontmostApp(name: "Notes", bundleID: "com.apple.notes"))
        let result = try await t.transcribe(emptyFeed(), options: TranscriptionOptions()) { _ in }
        #expect(result.style == "casual")
    }

    @Test("verbatim passthrough ignores fillers/punctuation toggles and leaves text identical to rawText")
    func verbatimPassthrough() async throws {
        let settings = StylingSettingsSnapshot(defaultStyle: .verbatim, removeFillers: true, autoPunctuate: true, snippetSayPrefix: false)
        let t = transcriber(rawText: "um so yeah thursday afternoon", settings: settings)
        let result = try await t.transcribe(emptyFeed(), options: TranscriptionOptions()) { _ in }
        #expect(result.text == result.rawText)
        #expect(result.text == "um so yeah thursday afternoon")
        #expect(result.fillersRemoved == 0)
        #expect(result.cursorOffset == nil)
        #expect(result.style == "verbatim")
    }

    @Test("snippet expansion in the styled text, with used triggers reported to noteUses")
    func snippetExpansionAndUsedCounters() async throws {
        let noted = NotedCalls()
        let content = snapshots(snippets: [SnippetRule(trigger: "/sig", body: "Best, Artem")],
                                noteUses: { text, snippets in noted.record(text: text, snippets: snippets) })
        let t = transcriber(rawText: "see you soon slash sig", content: content)
        let result = try await t.transcribe(emptyFeed(), options: TranscriptionOptions()) { _ in }
        #expect(result.text == "See you soon Best, Artem.")
        let calls = noted.calls
        #expect(calls.count == 1)
        #expect(calls[0].snippets == ["/sig"])
    }

    @Test("M2: noteUses is given the styled (pre-expansion) text, so a word only inside a snippet body is not counted as dictated")
    func noteUsesSeesStyledTextNotExpandedText() async throws {
        let noted = NotedCalls()
        let content = snapshots(snippets: [SnippetRule(trigger: "/sig", body: "Kubernetes expert, Artem")],
                                noteUses: { text, snippets in noted.record(text: text, snippets: snippets) })
        let t = transcriber(rawText: "see you soon slash sig", content: content)
        let result = try await t.transcribe(emptyFeed(), options: TranscriptionOptions()) { _ in }
        #expect(result.text.contains("Kubernetes"))
        let calls = noted.calls
        #expect(calls.count == 1)
        #expect(calls[0].text.contains("Kubernetes") == false)
    }

    @Test("partial text events are forwarded unmodified (still raw)")
    func partialEventsForwardedRaw() async throws {
        let result = DictationResult(text: "um raw text", rawText: "um raw text", segments: [], language: nil, duration: 1, lowConfidence: false)
        let base = FakeDictationTranscriber(result: result, events: [.partialText("um raw text")])
        let t = StyledTranscriber(base: base, styler: RuleStyler(), settings: StylingSettingsBox(StylingSettingsSnapshot(defaultStyle: .casual, removeFillers: true, autoPunctuate: true, snippetSayPrefix: false)),
                                  content: snapshots(), frontmost: FrontmostBox(nil), clipboard: { nil }, now: { Date() })
        let events = EventLog()
        _ = try await t.transcribe(emptyFeed(), options: TranscriptionOptions()) { await events.append($0) }
        #expect(await events.all == [.partialText("um raw text")])
    }
}

/// Records `noteUses` calls synchronously — `ContentSnapshots.noteUses` is a plain (non-async)
/// `@Sendable` closure, so a test can assert on it immediately after `transcribe()` returns.
final class NotedCalls: Sendable {
    private let box = Mutex(State())
    private struct State { var calls: [(text: String, snippets: [String])] = [] }
    func record(text: String, snippets: [String]) { box.withLock { $0.calls.append((text, snippets)) } }
    var calls: [(text: String, snippets: [String])] { box.withLock { $0.calls } }
}

/// Collects `onEvent` calls from an `async` callback — an `actor` rather than a `Mutex` box since
/// `append` itself is `async` here (mirrors the callback's own signature).
actor EventLog {
    private(set) var all: [DictationEvent] = []
    func append(_ event: DictationEvent) { all.append(event) }
}
