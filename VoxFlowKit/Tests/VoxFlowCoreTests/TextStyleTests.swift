import Testing
@testable import VoxFlowCore

@Suite("TextStyle")
struct TextStyleTests {
    @Test("display names")
    func displayNames() {
        #expect(TextStyle.formal.displayName == "Formal")
        #expect(TextStyle.casual.displayName == "Casual")
        #expect(TextStyle.veryCasual.displayName == "Very casual")
        #expect(TextStyle.verbatim.displayName == "Verbatim")
    }

    @Test("default is casual")
    func defaultStyle() {
        #expect(TextStyle.default == .casual)
    }

    @Test("all four cases round-trip through rawValue")
    func rawValueRoundTrip() {
        for style in TextStyle.allCases {
            #expect(TextStyle(rawValue: style.rawValue) == style)
        }
        #expect(TextStyle.allCases.count == 4)
    }
}
