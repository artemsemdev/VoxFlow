import AppKit
import Testing
@testable import VoxFlow

@Suite("FnKeyDecoder")
struct FnKeyDecoderTests {
    @Test("down on first fn flag, up when it clears, repeats ignored, other modifiers ignored")
    func transitions() {
        var d = FnKeyDecoder()
        #expect(d.decode(flags: [.function]) == .down)
        #expect(d.decode(flags: [.function]) == nil)
        #expect(d.decode(flags: [.function, .shift]) == nil)
        #expect(d.decode(flags: [.shift]) == .up)
        #expect(d.decode(flags: []) == nil)
        #expect(d.decode(flags: [.command]) == nil)
    }
}
