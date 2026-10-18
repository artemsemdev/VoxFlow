import Foundation
import Testing
import VoxFlowCore
import VoxFlowStyling
import VoxFlowTestSupport
@testable import VoxFlow

/// `Restyler` (MW-02s Re-style): rewrites a stored raw transcript into another tone through
/// whatever styler the app runs — LLM when ready, rules otherwise — applying the current global
/// styling toggles from `StylingSettingsBox`.
@Suite("Restyler")
struct RestylerTests {
    private func box(removeFillers: Bool = true, autoPunctuate: Bool = true) -> StylingSettingsBox {
        StylingSettingsBox(StylingSettingsSnapshot(defaultStyle: .casual, removeFillers: removeFillers,
                                                    autoPunctuate: autoPunctuate, snippetSayPrefix: false))
    }

    private func styler(backend: FakeLLMBackend) -> LlamaStyler {
        LlamaStyler(backend: backend, clock: FakeClock())
    }

    @Test("LLM reply is used when the backend is ready")
    func llmReplyUsedWhenReady() async throws {
        let backend = FakeLLMBackend(ready: true, reply: "Could we push the meeting to Thursday afternoon?")
        let restyler = Restyler(styler: styler(backend: backend), settings: box())

        let result = await restyler.restyle(rawText: "um can we push the meeting to thursday afternoon", to: .formal)

        #expect(result == "Could we push the meeting to Thursday afternoon?")
        #expect(await backend.prompts.count == 1)
    }

    @Test("rules are used when the backend is not ready")
    func rulesUsedWhenNotReady() async throws {
        let backend = FakeLLMBackend(ready: false, reply: "should never be seen")
        let restyler = Restyler(styler: styler(backend: backend), settings: box())
        let raw = "can we push the meeting um to thursday afternoon"

        let result = await restyler.restyle(rawText: raw, to: .formal)

        #expect(await backend.prompts.isEmpty)
        let expected = RuleStyler().styleSync(raw, options: StylingOptions(style: .formal, removeFillers: true, autoPunctuate: true)).text
        #expect(result == expected)
        #expect(!result.contains("um"))   // removeFillers true (the box's default) strips it
    }

    @Test("the box's toggles are applied: removeFillers false keeps \"um\"")
    func togglesFromBoxAreApplied() async throws {
        let backend = FakeLLMBackend(ready: false, reply: "should never be seen")
        let restyler = Restyler(styler: styler(backend: backend), settings: box(removeFillers: false))
        let raw = "can we push the meeting um to thursday afternoon"

        let result = await restyler.restyle(rawText: raw, to: .formal)

        #expect(result.contains("um"))
    }
}
