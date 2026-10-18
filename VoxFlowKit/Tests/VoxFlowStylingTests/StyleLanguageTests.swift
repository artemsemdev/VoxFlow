import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlowStyling

@Suite("Style language preservation")
struct StyleLanguageTests {
    @Test("a translated reply falls back to rules in every rewriting style",
          arguments: [TextStyle.formal, .casual, .veryCasual])
    func translationFallsBack(style: TextStyle) async throws {
        let raw = "встреча уже запланирована на завтра и все участники получили приглашения"
        let backend = FakeLLMBackend(ready: true, reply: "The meeting is scheduled for tomorrow and everyone has received an invitation.")
        let options = StylingOptions(style: style, removeFillers: true, autoPunctuate: true)
        let styler = LlamaStyler(backend: backend, clock: FakeClock())

        let result = try await styler.style(raw, options: options)

        #expect(await backend.prompts.count == 1)
        #expect(result == RuleStyler().styleSync(raw, options: options))
    }

    @Test("Russian cleanup can retain English product names")
    func russianCleanupIsAccepted() async throws {
        let raw = "отправь пожалуйста ссылку на встречу в Zoom через Telegram"
        let reply = "Отправь, пожалуйста, ссылку на встречу в Zoom через Telegram!"
        let backend = FakeLLMBackend(ready: true, reply: reply)
        let styler = LlamaStyler(backend: backend, clock: FakeClock())

        let result = try await styler.style(raw, options: StylingOptions(style: .casual, removeFillers: true, autoPunctuate: true))

        #expect(result.text == reply)
    }

    @Test("translations are rejected, including languages using the same alphabet",
          arguments: [
            ("Да, конечно.", "Yes, certainly."),
            ("Отправь отчёт завтра утром.", "Send the report tomorrow morning."),
            ("Send the report tomorrow morning.", "Отправь отчёт завтра утром."),
            ("Por favor, envía el informe mañana por la mañana.", "Please send the report tomorrow morning."),
            ("Bitte schicke den Bericht morgen früh an das gesamte Team.", "Please send the report to the whole team tomorrow morning.")
          ])
    func rejectsTranslation(input: String, output: String) {
        #expect(!OutputValidator.isAcceptable(output, input: input))
    }

    @Test("same-language rewrites remain usable",
          arguments: [
            ("Да, конечно.", "Конечно, да!"),
            ("отправь отчёт завтра утром", "Пожалуйста, отправь отчёт завтра утром."),
            ("please send the report tomorrow morning", "Could you send the report tomorrow morning?"),
            ("Por favor, envía el informe mañana por la mañana.", "¿Podrías enviar el informe mañana por la mañana, por favor?"),
            ("Bitte schicke den Bericht morgen früh an das gesamte Team.", "Könntest du den Bericht bitte morgen früh an das gesamte Team schicken?")
          ])
    func acceptsSameLanguage(input: String, output: String) {
        #expect(OutputValidator.isAcceptable(output, input: input))
    }

    @Test("unidentifiable language cannot authorize a model rewrite")
    func unknownLanguageFallsBack() {
        #expect(!OutputValidator.isAcceptable("42!", input: "42"))
    }
}
