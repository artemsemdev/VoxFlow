import Foundation
import VoxFlowCore
import VoxFlowStyling

/// Re-style (MW-02s): rewrite a stored raw transcript into another tone with the current global
/// toggles, through whatever styler the app runs (LLM when ready, rules otherwise).
struct Restyler: Sendable {
    let styler: any TextStyler
    let settings: StylingSettingsBox

    func restyle(rawText: String, to style: TextStyle) async -> String {
        let snapshot = settings.current
        let options = StylingOptions(style: style, removeFillers: snapshot.removeFillers, autoPunctuate: snapshot.autoPunctuate)
        return (try? await styler.style(rawText, options: options))?.text ?? RuleStyler().styleSync(rawText, options: options).text
    }
}
