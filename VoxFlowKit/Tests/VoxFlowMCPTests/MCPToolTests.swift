import Testing
@testable import VoxFlowMCP

@Suite("MCPToolID")
struct MCPToolTests {
    @Test("transcribeFile descriptor has the verbatim name, description, and requires 'path'")
    func transcribeFileDescriptor() {
        let descriptor = MCPToolID.transcribeFile.descriptor
        #expect(descriptor.name == "transcribe_file")
        #expect(descriptor.description == "Transcribe an audio file at a path; returns text or SRT")
        let required = descriptor.inputSchema["required"]?.arrayValue?.compactMap { $0.stringValue }
        #expect(required == ["path"])
    }

    @Test("dictate descriptor has the verbatim name and description")
    func dictateDescriptor() {
        let descriptor = MCPToolID.dictate.descriptor
        #expect(descriptor.name == "dictate")
        #expect(descriptor.description == "Start a dictation and return the cleaned-up text")
    }

    @Test("searchHistory descriptor has the verbatim name and description")
    func searchHistoryDescriptor() {
        let descriptor = MCPToolID.searchHistory.descriptor
        #expect(descriptor.name == "search_history")
        #expect(descriptor.description == "Search past dictations — off by default")
    }

    @Test("MCPToolID resolves from its wire name, and rejects an unknown one")
    func resolvesFromWireName() {
        #expect(MCPToolID(toolName: "transcribe_file") == .transcribeFile)
        #expect(MCPToolID(toolName: "dictate") == .dictate)
        #expect(MCPToolID(toolName: "search_history") == .searchHistory)
        #expect(MCPToolID(toolName: "nope") == nil)
    }
}
