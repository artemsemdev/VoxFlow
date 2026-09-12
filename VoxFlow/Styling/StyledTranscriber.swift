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
        try await transcribe(chunks, options: options, processingDeadline: { nil }, onEvent: onEvent)
    }

    func transcribe(_ chunks: AsyncStream<AudioChunk>, options: TranscriptionOptions,
                    processingDeadline: @escaping @Sendable () -> TimeInterval?,
                    onEvent: @Sendable @escaping (DictationEvent) async -> Void) async throws -> DictationResult {
        let result = try await base.transcribe(chunks, options: options,
                                              processingDeadline: processingDeadline, onEvent: onEvent)

        let app = frontmost.current
        let snapshot = settings.current
        let style = StyleResolver.resolve(default: snapshot.defaultStyle, overrides: content.overridesBox.current, bundleID: app?.bundleID)
        // Leave one second for snippet expansion, insertion dispatch and the reducer to finish.
        let stylingOptions = StylingOptions(style: style, removeFillers: snapshot.removeFillers,
            autoPunctuate: snapshot.autoPunctuate, generationDeadline: processingDeadline().map { $0 - 1 })
        let styled: StyledText
        do {
            styled = try await styler.style(result.rawText, options: stylingOptions)
        } catch {
            // A styling failure must never lose a dictation (ADR-007): fall back to the
            // deterministic rule-based styler with the same options.
            styled = RuleStyler().styleSync(result.rawText, options: stylingOptions)
        }

        let expander = SnippetExpander(snippets: content.snippetsBox.current, sayPrefix: snapshot.snippetSayPrefix,
                                       context: (date: now(), clipboard: clipboard(), appName: app?.name, bundleID: app?.bundleID))
        let expanded = expander.expand(styled.text)

        // M2: counts uses from the styled text *before* snippet expansion, so a dictionary word that
        // only appears inside an expanded snippet body (or a `clipboard` paste) is never counted as
        // dictated — `DictionaryStore.incrementUses(inText:)` folds and matches whole
        // words/phrases (I3) itself.
        content.noteUses(styled.text, expanded.used)

        let annotations = DictationAnnotations(removedFillerSpans: styled.removedFillerSpans,
                                              wordConfidences: result.annotations?.wordConfidences)
        return DictationResult(text: expanded.text, rawText: result.rawText, segments: result.segments,
                               language: result.language, duration: result.duration, lowConfidence: result.lowConfidence,
                               style: style.rawValue, cursorOffset: expanded.cursorOffset, fillersRemoved: styled.fillersRemoved,
                               annotations: annotations)
    }
}
