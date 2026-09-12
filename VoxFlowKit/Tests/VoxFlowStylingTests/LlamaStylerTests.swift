import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlowStyling

@Suite("LlamaStyler")
struct LlamaStylerTests {
    private func options(style: TextStyle = .formal, removeFillers: Bool = true, autoPunctuate: Bool = true) -> StylingOptions {
        StylingOptions(style: style, removeFillers: removeFillers, autoPunctuate: autoPunctuate)
    }

    private func makeStyler(backend: FakeLLMBackend, clock: FakeClock = FakeClock(), limits: StyleLimits = StyleLimits()) -> LlamaStyler {
        LlamaStyler(backend: backend, rules: RuleStyler(), limits: limits, clock: clock)
    }

    @Test("formal prompt is exact: system prompt matches StylePrompts, user text is the pre-passed text, result is the reply")
    func formalPromptIsExact() async throws {
        let reply = "Could we move the meeting to Thursday afternoon? I need the numbers from Finance first."
        let backend = FakeLLMBackend(ready: true, reply: reply)
        let styler = makeStyler(backend: backend)

        let result = try await styler.style("um can we push the meeting to thursday", options: options(style: .formal))

        let prompts = await backend.prompts
        #expect(prompts.count == 1)
        #expect(prompts.first?.system == StylePrompts.system(for: .formal))
        #expect(prompts.first?.user == "Can we push the meeting to thursday.")
        #expect(result.text == reply)
        #expect(result.fillersRemoved == 1)
    }

    @Test("casual prompt uses StylePrompts.system(for: .casual); the reply is used as the result")
    func casualPromptIsExact() async throws {
        let reply = "hey, can we push the meeting to thursday afternoon?"
        let backend = FakeLLMBackend(ready: true, reply: reply)
        let styler = makeStyler(backend: backend)

        let result = try await styler.style("um can we push the meeting to thursday", options: options(style: .casual))

        let prompts = await backend.prompts
        #expect(prompts.first?.system == StylePrompts.system(for: .casual))
        #expect(result.text == reply)
    }

    @Test("very casual prompt uses StylePrompts.system(for: .veryCasual); the reply is used as the result")
    func veryCasualPromptIsExact() async throws {
        let reply = "hey can we push it to thursday"
        let backend = FakeLLMBackend(ready: true, reply: reply)
        let styler = makeStyler(backend: backend)

        let result = try await styler.style("um can we push the meeting to thursday", options: options(style: .veryCasual))

        let prompts = await backend.prompts
        #expect(prompts.first?.system == StylePrompts.system(for: .veryCasual))
        #expect(result.text == reply)
    }

    @Test("verbatim skips the backend entirely")
    func verbatimSkipsBackend() async throws {
        let backend = FakeLLMBackend(ready: true, reply: "should never be seen")
        let styler = makeStyler(backend: backend)

        let result = try await styler.style("um raw text", options: options(style: .verbatim))

        let prompts = await backend.prompts
        #expect(prompts.isEmpty)
        #expect(result.text == "um raw text")
    }

    @Test("backend not ready falls back to RuleStyler with no prompts recorded")
    func notReadyFallsBackToRules() async throws {
        let backend = FakeLLMBackend(ready: false, reply: "ignored")
        let styler = makeStyler(backend: backend)
        let raw = "um can we push the meeting to thursday"
        let opts = options(style: .formal)

        let result = try await styler.style(raw, options: opts)

        let prompts = await backend.prompts
        #expect(prompts.isEmpty)
        #expect(result == RuleStyler().styleSync(raw, options: opts))
    }

    @Test("input over the word cap falls back to RuleStyler with no prompts recorded")
    func overCapFallsBackToRules() async throws {
        let backend = FakeLLMBackend(ready: true, reply: "ignored")
        let styler = makeStyler(backend: backend)
        let raw = Array(repeating: "word", count: 151).joined(separator: " ")

        _ = try await styler.style(raw, options: options(style: .formal))

        let prompts = await backend.prompts
        #expect(prompts.isEmpty)
    }

    @Test("empty reply falls back to RuleStyler")
    func emptyReplyFallsBack() async throws {
        let backend = FakeLLMBackend(ready: true, reply: "")
        let styler = makeStyler(backend: backend)
        let raw = "we should meet on thursday afternoon"
        let opts = options(style: .formal)

        let result = try await styler.style(raw, options: opts)

        #expect(result == RuleStyler().styleSync(raw, options: opts))
    }

    @Test("garbage reply (special tokens) falls back to RuleStyler")
    func garbageReplyFallsBack() async throws {
        let backend = FakeLLMBackend(ready: true, reply: "<|im_start|>assistant")
        let styler = makeStyler(backend: backend)
        let raw = "we should meet on thursday afternoon"
        let opts = options(style: .formal)

        let result = try await styler.style(raw, options: opts)

        #expect(result == RuleStyler().styleSync(raw, options: opts))
    }

    @Test("a reply far shorter than the input falls back to RuleStyler")
    func tooShortReplyFallsBack() async throws {
        let backend = FakeLLMBackend(ready: true, reply: "ok")
        let styler = makeStyler(backend: backend)
        let raw = Array(repeating: "word", count: 20).joined(separator: " ")
        let opts = options(style: .formal)

        let result = try await styler.style(raw, options: opts)

        #expect(result == RuleStyler().styleSync(raw, options: opts))
    }

    @Test("surrounding quotes are stripped from the reply")
    func quotesAreStripped() async throws {
        let backend = FakeLLMBackend(ready: true, reply: "\"hello there\"")
        let styler = makeStyler(backend: backend)

        let result = try await styler.style("hello there", options: options(style: .formal))

        #expect(result.text == "hello there")
    }

    @Test("generation past the timeout falls back to RuleStyler; the backend still received the prompt")
    func timeoutFallsBack() async throws {
        let backend = FakeLLMBackend(ready: true, reply: "should never be used")
        await backend.set(hangs: true)
        let clock = FakeClock()
        let styler = makeStyler(backend: backend, clock: clock)
        let raw = "we should meet on thursday afternoon"
        let opts = options(style: .formal)

        let task = Task { try await styler.style(raw, options: opts) }
        await clock.waitForSleepers(1)
        await backend.waitForFirstPrompt()
        await clock.advance(by: 8)
        let result = try await task.value

        #expect(result == RuleStyler().styleSync(raw, options: opts))
        let prompts = await backend.prompts
        #expect(prompts.count == 1)
    }

    @Test("a backend error falls back to RuleStyler")
    func errorFallsBack() async throws {
        let backend = FakeLLMBackend(ready: true, reply: "ignored")
        await backend.set(error: .decodeFailed(code: 1))
        let styler = makeStyler(backend: backend)
        let raw = "we should meet on thursday afternoon"
        let opts = options(style: .formal)

        let result = try await styler.style(raw, options: opts)

        #expect(result == RuleStyler().styleSync(raw, options: opts))
    }

    @Test("maxNewTokens follows the pre-passed word count, capped")
    func maxNewTokensFollowsWords() async throws {
        let backend = FakeLLMBackend(ready: true, reply: "Could we please meet on Thursday afternoon instead of the usual time.")
        let styler = makeStyler(backend: backend)
        let raw = Array(repeating: "word", count: 10).joined(separator: " ")

        _ = try await styler.style(raw, options: options(style: .formal, removeFillers: false, autoPunctuate: false))

        let maxTokens = await backend.maxTokens
        #expect(maxTokens.first == 62)

        let limits = StyleLimits()
        #expect(limits.maxNewTokens(forWords: 300) == 768)
    }
}

@Suite("StylePrompts")
struct StylePromptsTests {
    private static let tail = "Keep every fact, name, number and the original meaning, and write in the same language as the user's text. Do not add greetings, sign-offs, emoji, explanations or quotes. Reply with the rewritten text only."

    @Test("every non-verbatim system prompt ends with the shared tail")
    func nonVerbatimPromptsEndWithTail() {
        for style: TextStyle in [.formal, .casual, .veryCasual] {
            let prompt = StylePrompts.system(for: style)
            #expect(prompt?.hasSuffix(Self.tail) == true)
        }
    }

    @Test("verbatim has no system prompt")
    func verbatimHasNoPrompt() {
        #expect(StylePrompts.system(for: .verbatim) == nil)
    }

    @Test("prompt(for:text:) wraps the system prompt with the given user text")
    func promptWrapsUserText() {
        let prompt = StylePrompts.prompt(for: .casual, text: "hello there")
        #expect(prompt?.system == StylePrompts.system(for: .casual))
        #expect(prompt?.user == "hello there")
    }

    @Test("prompt(for:text:) is nil for verbatim")
    func promptNilForVerbatim() {
        #expect(StylePrompts.prompt(for: .verbatim, text: "hello there") == nil)
    }
}

@Suite("OutputValidator")
struct OutputValidatorTests {
    @Test("clean trims whitespace and strips a single layer of surrounding quotes")
    func cleanStripsQuotes() {
        #expect(OutputValidator.clean("  \"hello there\"  ") == "hello there")
        #expect(OutputValidator.clean("no quotes here") == "no quotes here")
    }

    @Test("clean collapses blank lines and trims each line")
    func cleanCollapsesBlankLines() {
        #expect(OutputValidator.clean("line one\n\n  line two  \n") == "line one\nline two")
    }

    @Test("isAcceptable rejects empty output")
    func rejectsEmptyOutput() {
        #expect(OutputValidator.isAcceptable("", input: "hello there") == false)
    }

    @Test("isAcceptable rejects output containing special tokens")
    func rejectsSpecialTokens() {
        #expect(OutputValidator.isAcceptable("<|im_start|>assistant", input: "hello there") == false)
    }

    @Test("isAcceptable rejects output identical to the input")
    func rejectsIdenticalOutput() {
        #expect(OutputValidator.isAcceptable("hello there", input: "hello there") == false)
    }

    @Test("isAcceptable accepts the ratio lower bound at exactly 30%")
    func acceptsRatioLowerBound() {
        let input = Array(repeating: "word", count: 10).joined(separator: " ")
        let output = Array(repeating: "different", count: 3).joined(separator: " ")
        #expect(OutputValidator.isAcceptable(output, input: input) == true)
    }

    @Test("isAcceptable rejects just below the ratio lower bound")
    func rejectsBelowRatioLowerBound() {
        let input = Array(repeating: "word", count: 10).joined(separator: " ")
        let output = Array(repeating: "different", count: 2).joined(separator: " ")
        #expect(OutputValidator.isAcceptable(output, input: input) == false)
    }

    @Test("isAcceptable accepts the ratio upper bound at exactly 300%")
    func acceptsRatioUpperBound() {
        let input = Array(repeating: "word", count: 10).joined(separator: " ")
        let output = Array(repeating: "different", count: 30).joined(separator: " ")
        #expect(OutputValidator.isAcceptable(output, input: input) == true)
    }

    @Test("isAcceptable rejects just above the ratio upper bound")
    func rejectsAboveRatioUpperBound() {
        let input = Array(repeating: "word", count: 10).joined(separator: " ")
        let output = Array(repeating: "different", count: 31).joined(separator: " ")
        #expect(OutputValidator.isAcceptable(output, input: input) == false)
    }
}
