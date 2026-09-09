import Foundation
import Synchronization
import VoxFlowCore
import VoxFlowDictation
import VoxFlowStyling

/// Sendable box holding the app that was frontmost when this capture's `PreflightBuilder` cleared
/// every gate (ruling 3: the app captured at fn-down, not whichever app happens to be frontmost once
/// styling actually runs after the window loop returns) — filled by `PreflightBuilder`'s
/// `onFrontmostCaptured` hook, read here.
final class FrontmostBox: Sendable {
    private let box: Mutex<FrontmostApp?>
    init(_ initial: FrontmostApp? = nil) { box = Mutex(initial) }
    var current: FrontmostApp? { box.withLock { $0 } }
    func set(_ app: FrontmostApp?) { box.withLock { $0 = app } }
}

/// Decorator around a base `DictationTranscribing`: forwards the chunk feed and every `DictationEvent`
/// unchanged (ruling 3: partial text stays raw), then — once the base transcriber returns — resolves
/// the effective style for the captured frontmost app, runs `RuleStyler`, expands snippets in the
/// styled text, and returns a `DictationResult` whose `text` is the styled+expanded output while
/// `rawText` stays the engine's own output. Fires `content.noteUses` (fire-and-forget) to bump
/// dictionary/snippet usage counters.
struct StyledTranscriber: DictationTranscribing {
    let base: any DictationTranscribing
    let styler: any TextStyler
    let settings: StylingSettingsBox
    let content: ContentSnapshots
    let frontmost: FrontmostBox
    let clipboard: @Sendable () -> String?
    let now: @Sendable () -> Date

    func transcribe(_ chunks: AsyncStream<AudioChunk>, options: TranscriptionOptions,
                    onEvent: @Sendable @escaping (DictationEvent) async -> Void) async throws -> DictationResult {
        let result = try await base.transcribe(chunks, options: options, onEvent: onEvent)

        let app = frontmost.current
        let snapshot = settings.current
        let style = StyleResolver.resolve(default: snapshot.defaultStyle, overrides: content.overridesBox.current, bundleID: app?.bundleID)
        let stylingOptions = StylingOptions(style: style, removeFillers: snapshot.removeFillers, autoPunctuate: snapshot.autoPunctuate)
        let styled = styler.style(result.rawText, options: stylingOptions)

        let expander = SnippetExpander(snippets: content.snippetsBox.current, sayPrefix: snapshot.snippetSayPrefix,
                                       context: (date: now(), clipboard: clipboard(), appName: app?.name, bundleID: app?.bundleID))
        let expanded = expander.expand(styled.text)

        content.noteUses(Self.wholeWords(in: expanded.text), expanded.used)

        return DictationResult(text: expanded.text, rawText: result.rawText, segments: result.segments,
                               language: result.language, duration: result.duration, lowConfidence: result.lowConfidence,
                               style: style.rawValue, cursorOffset: expanded.cursorOffset, fillersRemoved: styled.fillersRemoved)
    }

    /// Tokenizes styled text into whole words for `DictionaryStore.incrementUses(words:)`, which
    /// folds each candidate before matching it against `word_folded` (ruling 5: "case-insensitive
    /// whole word").
    private static func wholeWords(in text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
