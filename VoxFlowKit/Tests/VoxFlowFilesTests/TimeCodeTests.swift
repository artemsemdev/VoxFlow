import Testing
@testable import VoxFlowFiles

@Suite("TimeCode")
struct TimeCodeTests {
    @Test("srt/vtt/bracket formats with millisecond rounding")
    func formats() {
        #expect(TimeCode.srt(4.1204) == "00:00:04,120")
        #expect(TimeCode.vtt(3661.5) == "01:01:01.500")
        #expect(TimeCode.bracket(0) == "00:00:00.000")
        #expect(TimeCode.srt(0.9995) == "00:00:01,000")
    }

    @Test("short form drops hours when zero")
    func short() {
        #expect(TimeCode.short(9.86) == "0:10")
        #expect(TimeCode.short(5530) == "1:32:10")
        #expect(TimeCode.short(59.7) == "1:00")
    }
}
