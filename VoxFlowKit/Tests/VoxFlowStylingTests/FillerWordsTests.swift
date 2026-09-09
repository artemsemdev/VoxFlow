import Testing
@testable import VoxFlowStyling

@Suite("FillerWords")
struct FillerWordsTests {
    @Test("every simple filler pattern is removed", arguments: [
        "um", "uh", "erm", "hmm", "you know", "I mean", "sort of", "kind of",
    ])
    func removesEachPattern(_ filler: String) {
        let (text, removed) = FillerWords.strip("I was, \(filler), walking")
        #expect(text == "I was, walking")
        #expect(removed == 1)
    }

    @Test("matching is case-insensitive")
    func caseInsensitive() {
        let (text, removed) = FillerWords.strip("UM, I think so")
        #expect(text == "I think so")
        #expect(removed == 1)
    }

    @Test("like set off by commas is removed")
    func likeBetweenCommas() {
        let (text, removed) = FillerWords.strip("This is, like, cool")
        #expect(text == "This is, cool")
        #expect(removed == 1)
    }

    @Test("like at a clause start followed by a comma is removed")
    func likeAtClauseStart() {
        let (text, removed) = FillerWords.strip("Like, I think so")
        #expect(text == "I think so")
        #expect(removed == 1)
    }

    @Test("M3: like opening a clause after a sentence end (not just the very start of the text) is removed")
    func likeAtClauseStartMidText() {
        let (text, removed) = FillerWords.strip("It's late. Like, we should go")
        #expect(text == "It's late. we should go")
        #expect(removed == 1)
    }

    @Test("a plain verb 'like' is not removed")
    func likeAsVerbKept() {
        let (text, removed) = FillerWords.strip("I really like it")
        #expect(text == "I really like it")
        #expect(removed == 0)
    }

    @Test("multiple fillers are all removed and counted")
    func multipleFillers() {
        let (text, removed) = FillerWords.strip("Um, I mean, this is, you know, important")
        #expect(text == "this is, important")
        #expect(removed == 3)
    }

    @Test("doubled spaces are collapsed after removal")
    func collapsesDoubleSpaces() {
        let (text, removed) = FillerWords.strip("I um think so")
        #expect(text == "I think so")
        #expect(removed == 1)
    }

    @Test("no fillers present leaves text untouched")
    func noFillers() {
        let (text, removed) = FillerWords.strip("This is a clean sentence")
        #expect(text == "This is a clean sentence")
        #expect(removed == 0)
    }
}
