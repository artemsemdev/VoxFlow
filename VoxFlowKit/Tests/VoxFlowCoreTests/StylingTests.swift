import Testing
@testable import VoxFlowCore

@Suite("Styling core types")
struct StylingTests {
    private struct EchoStyler: TextStyler {
        func style(_ raw: String, options: StylingOptions) async throws -> StyledText {
            StyledText(text: raw, fillersRemoved: 0, cursorOffset: nil)
        }
    }

    @Test("StylingOptions is an equatable value type")
    func stylingOptionsEquatable() {
        let options = StylingOptions(style: .casual, removeFillers: true, autoPunctuate: true)
        let same = StylingOptions(style: .casual, removeFillers: true, autoPunctuate: true)
        let different = StylingOptions(style: .formal, removeFillers: true, autoPunctuate: true)
        #expect(options == same)
        #expect(options != different)
    }

    @Test("StyledText is an equatable value type")
    func styledTextEquatable() {
        let styled = StyledText(text: "hi", fillersRemoved: 1, cursorOffset: 2)
        #expect(styled == StyledText(text: "hi", fillersRemoved: 1, cursorOffset: 2))
        #expect(styled != StyledText(text: "hi", fillersRemoved: 0, cursorOffset: 2))
    }

    @Test("cursorOffset defaults to nil")
    func cursorOffsetDefaultsToNil() {
        let styled = StyledText(text: "hi", fillersRemoved: 0)
        #expect(styled.cursorOffset == nil)
    }

    @Test("a TextStyler implementation can be driven through the protocol")
    func protocolConformance() async throws {
        let styler: TextStyler = EchoStyler()
        let result = try await styler.style("hello", options: StylingOptions(style: .casual, removeFillers: false, autoPunctuate: false))
        #expect(result.text == "hello")
        #expect(result.fillersRemoved == 0)
    }
}
