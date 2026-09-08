import Testing
@testable import VoxFlowCore

@Suite("OutputFormat")
struct OutputFormatTests {
    @Test("five formats in the design's order; txt is default")
    func order() {
        #expect(OutputFormat.allCases == [.txt, .srt, .vtt, .json, .md])
        #expect(OutputFormat.default == .txt)
    }

    @Test("file extension and display name", arguments: [
        (OutputFormat.txt, "txt", "TXT"), (.srt, "srt", "SRT"), (.vtt, "vtt", "VTT"), (.json, "json", "JSON"), (.md, "md", "MD"),
    ])
    func names(format: OutputFormat, ext: String, name: String) {
        #expect(format.fileExtension == ext)
        #expect(format.displayName == name)
    }

    @Test("parses config values case-insensitively, with markdown as an alias")
    func parsing() {
        #expect(OutputFormat(configValue: "SRT") == .srt)
        #expect(OutputFormat(configValue: "markdown") == .md)
        #expect(OutputFormat(configValue: "docx") == nil)
    }

    @Test("only txt and md honour the timestamps toggle")
    func timestampsToggle() {
        #expect(OutputFormat.txt.supportsTimestampToggle)
        #expect(OutputFormat.md.supportsTimestampToggle)
        #expect(!OutputFormat.srt.supportsTimestampToggle && !OutputFormat.vtt.supportsTimestampToggle && !OutputFormat.json.supportsTimestampToggle)
    }
}
