import Foundation
import VoxFlowCore
import VoxFlowStyling

/// Re-style (MW-02s): rewrite a stored raw transcript into another tone with the current global
/// toggles, through whatever styler the app runs (LLM when ready, rules otherwise).
struct Restyler: Sendable {
    let styler: any TextStyler
    let settings: StylingSettingsBox

    func restyle(rawText: String, to style: TextStyle) async -> String {
        await restyleResult(rawText: rawText, to: style).text
    }

    func restyleResult(rawText: String, to style: TextStyle) async -> StyledText {
        let snapshot = settings.current
        let options = StylingOptions(style: style, removeFillers: snapshot.removeFillers, autoPunctuate: snapshot.autoPunctuate)
        // `styler` is `any TextStyler`, not statically `LlamaStyler` — the app only ever runs
        // `LlamaStyler` here (documented never to throw, always falling back to `RuleStyler`
        // internally), but the protocol itself is `throws`, so this `try?`/`??` stays as the same
        // belt-and-braces guarantee for any conforming implementation: a Re-style must never throw.
        return (try? await styler.style(rawText, options: options)) ?? RuleStyler().styleSync(rawText, options: options)
    }
}
