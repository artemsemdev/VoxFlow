import Testing
import VoxFlowCore
@testable import VoxFlowStyling

@Suite("RuleStyler")
struct RuleStylerTests {
    private let styler = RuleStyler()

    private func options(
        style: TextStyle = .casual,
        removeFillers: Bool = false,
        autoPunctuate: Bool = false
    ) -> StylingOptions {
        StylingOptions(style: style, removeFillers: removeFillers, autoPunctuate: autoPunctuate)
    }

    // MARK: fillers

    @Test("removeFillers strips fillers and reports the count")
    func removeFillersOn() {
        let result = styler.style(
            "Um, I was, like, walking",
            options: options(removeFillers: true)
        )
        #expect(result.text == "I was, walking")
        #expect(result.fillersRemoved == 2)
    }

    @Test("removeFillers off leaves fillers untouched")
    func removeFillersOff() {
        let result = styler.style("Um, I was walking", options: options(removeFillers: false))
        #expect(result.text == "Um, I was walking")
        #expect(result.fillersRemoved == 0)
    }

    // MARK: auto-punctuate

    @Test("capitalizes standalone i and adds a terminal period")
    func standaloneIAndTerminalPeriod() {
        let result = styler.style("i think so", options: options(autoPunctuate: true))
        #expect(result.text == "I think so.")
    }

    @Test("an existing terminal question mark is kept, not replaced by a period")
    func keepsExistingQuestionMark() {
        let result = styler.style("are you sure?", options: options(autoPunctuate: true))
        #expect(result.text == "Are you sure?")
    }

    @Test("capitalizes after sentence punctuation and a mid-sentence standalone i")
    func capitalizesAfterSentenceBoundary() {
        let result = styler.style(
            "well i guess so. is that right",
            options: options(autoPunctuate: true)
        )
        #expect(result.text == "Well I guess so. Is that right.")
    }

    @Test("double spaces are collapsed")
    func collapsesDoubleSpaces() {
        let result = styler.style("hello   there", options: options(autoPunctuate: true))
        #expect(result.text == "Hello there.")
    }

    @Test("a space is inserted after , . ? ! when followed directly by a letter")
    func insertsSpaceAfterPunctuation() {
        let result = styler.style("Hi,there. How are you?", options: options(autoPunctuate: true))
        #expect(result.text == "Hi, there. How are you?")
    }

    @Test("autoPunctuate off leaves capitalization and terminal punctuation untouched")
    func autoPunctuateOff() {
        let result = styler.style("i think so", options: options(autoPunctuate: false))
        #expect(result.text == "i think so")
    }

    // MARK: formal

    @Test("formal expands contractions from the fixed table, preserving initial capitalization")
    func formalExpandsContractions() {
        let result = styler.style(
            "I'm gonna call you, we're wanna go",
            options: options(style: .formal)
        )
        #expect(result.text == "I am going to call you, we are want to go")
    }

    @Test("formal preserves capital letter on a capitalized contraction")
    func formalPreservesCapital() {
        let result = styler.style("Can't we go", options: options(style: .formal))
        #expect(result.text == "Cannot we go")
    }

    @Test("formal does not attempt LLM-style rewrites, only table contractions")
    func formalDoesNotRewrite() {
        let result = styler.style("Could we move the meeting", options: options(style: .formal))
        #expect(result.text == "Could we move the meeting")
    }

    // MARK: casual

    @Test("casual applies no extra rules beyond the shared pipeline")
    func casualIsIdentityBeyondPipeline() {
        let result = styler.style("I'm gonna go", options: options(style: .casual))
        #expect(result.text == "I'm gonna go")
    }

    // MARK: very casual

    @Test("very casual lowercases everything and drops the terminal period")
    func veryCasualLowercasesAndDropsPeriod() {
        let result = styler.style(
            "we should meet tomorrow",
            options: options(style: .veryCasual, autoPunctuate: true)
        )
        #expect(result.text == "we should meet tomorrow")
    }

    @Test("very casual keeps a non-period terminal mark")
    func veryCasualKeepsQuestionMark() {
        let result = styler.style(
            "Are you free?",
            options: options(style: .veryCasual, autoPunctuate: true)
        )
        #expect(result.text == "are you free?")
    }

    // MARK: Unicode safety

    @Test("capitalizing a German ß does not trap even though its uppercase form is two characters")
    func capitalizesMultiGraphemeUppercase() {
        let result = styler.style("ß is a letter", options: options(autoPunctuate: true))
        #expect(result.text == "SS is a letter.")
    }

    @Test("capitalizing text starting with an emoji or a combining mark does not trap")
    func capitalizesEmojiOrCombiningMarkSafely() {
        let emojiResult = styler.style("👍 great job", options: options(autoPunctuate: true))
        #expect(emojiResult.text == "👍 great job.")

        let combining = "e\u{0301}llo there" // "é" as e + combining acute accent, decomposed
        let combiningResult = styler.style(combining, options: options(autoPunctuate: true))
        #expect(combiningResult.text == "Éllo there.")
    }

    // MARK: verbatim

    @Test("verbatim ignores both toggles and returns raw text unchanged")
    func verbatimIgnoresToggles() {
        let result = styler.style(
            "  Um, i think SO  ",
            options: options(style: .verbatim, removeFillers: true, autoPunctuate: true)
        )
        #expect(result.text == "  Um, i think SO  ")
        #expect(result.fillersRemoved == 0)
        #expect(result.cursorOffset == nil)
    }
}
