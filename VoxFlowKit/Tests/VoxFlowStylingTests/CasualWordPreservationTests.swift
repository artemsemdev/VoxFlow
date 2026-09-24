import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlowStyling

@Suite("Casual preserves dictated words")
struct CasualWordPreservationTests {
    @Test("Casual rejects added, replaced, removed or reordered words",
          arguments: [
            ("Нужно обязательно добавить защиту на сайты с двухфакторной идентификацией.",
             "Нужно definitely добавить защиту на сайты с двухфакторной идентификацией, так удобнее."),
            ("Нужно обязательно добавить защиту на сайты с двухфакторной идентификацией.",
             "Нужно обязательно добавить защиту на сайты с двухфакторной идентификацией, так удобнее."),
            ("Нужно обязательно добавить защиту на сайты.", "Нужно непременно добавить защиту на сайты."),
            ("Не отправляй отчёт сегодня.", "Отправляй отчёт сегодня."),
            ("Анна встретила Марию утром.", "Марию встретила Анна утром."),
            ("Please send the report tomorrow.", "Please send the report tomorrow, it is urgent."),
            ("Температура завтра будет -5 градусов.", "Температура завтра будет 5 градусов."),
            ("Цена заказа составляет 15.5 евро.", "Цена заказа составляет 15 5 евро."),
            ("Напиши завтра в Zoom и Telegram.", "Напиши завтра в Zoom и WhatsApp.")
          ])
    func rejectsChangedWords(raw: String, reply: String) async throws {
        let backend = FakeLLMBackend(ready: true, reply: reply)
        let options = StylingOptions(style: .casual, removeFillers: true, autoPunctuate: true)
        let result = try await LlamaStyler(backend: backend, clock: FakeClock()).style(raw, options: options)

        #expect(await backend.prompts.count == 1)
        #expect(result == RuleStyler().styleSync(raw, options: options))
    }

    @Test("Casual accepts punctuation and capitalization without changing words",
          arguments: [
            ("пожалуйста отправь отчёт завтра", "Пожалуйста, отправь отчёт завтра!"),
            ("отправь ссылку в Zoom и Telegram", "Отправь ссылку в Zoom и Telegram!"),
            ("we should meet tomorrow", "We should meet tomorrow!"),
            ("i can't attend tomorrow", "I can’t attend tomorrow!"),
            ("Отправь письмо José завтра.", "Отправь письмо Jose\u{301} завтра!")
          ])
    func acceptsPunctuation(raw: String, reply: String) async throws {
        let backend = FakeLLMBackend(ready: true, reply: reply)
        let options = StylingOptions(style: .casual, removeFillers: true, autoPunctuate: true)
        let result = try await LlamaStyler(backend: backend, clock: FakeClock()).style(raw, options: options)

        #expect(result.text == reply)
    }

    @Test("only the configured rule pass may remove fillers", arguments: [true, false])
    func respectsFillerSetting(removeFillers: Bool) async throws {
        let raw = "um please send the report tomorrow"
        let reply = "Please send the report tomorrow!"
        let backend = FakeLLMBackend(ready: true, reply: reply)
        let options = StylingOptions(style: .casual, removeFillers: removeFillers, autoPunctuate: true)
        let result = try await LlamaStyler(backend: backend, clock: FakeClock()).style(raw, options: options)

        #expect(result.text == (removeFillers ? reply : RuleStyler().styleSync(raw, options: options).text))
        #expect(result.fillersRemoved == (removeFillers ? 1 : 0))
    }
}
