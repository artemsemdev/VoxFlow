import Testing
import VoxFlowCore

@Suite("String.wordCount")
struct StringWordCountTests {
    @Test("splits on whitespace and newlines; empty and blank strings count zero")
    func wordCount() {
        #expect("hello there world".wordCount == 3)
        #expect("hello\nthere\tworld".wordCount == 3)
        #expect("  leading and trailing  ".wordCount == 3)
        #expect("".wordCount == 0)
        #expect("   ".wordCount == 0)
        #expect("one".wordCount == 1)
    }
}
