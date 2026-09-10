import Foundation
import Testing
import VoxFlowMCP
@testable import VoxFlow

@Suite("HTTPMessage")
struct HTTPMessageTests {
    @Test("a request split across three chunks parses only once complete")
    func splitAcrossChunks() {
        let full = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 5\r\n\r\nhello"
        let bytes = Array(full.utf8)
        let chunk1 = Data(bytes[0..<10])
        let chunk2 = Data(bytes[0..<40])
        let chunk3 = Data(bytes)

        #expect(HTTPMessage.parse(chunk1) == nil)
        #expect(HTTPMessage.parse(chunk2) == nil)

        let request = HTTPMessage.parse(chunk3)
        #expect(request != nil)
        #expect(request?.method == "POST")
        #expect(request?.path == "/mcp")
        #expect(request?.body == Data("hello".utf8))
    }

    @Test("a Content-Length shorter than the accumulated body truncates to the declared length")
    func contentLengthTruncates() {
        let full = "POST /mcp HTTP/1.1\r\nContent-Length: 3\r\n\r\nhello world"
        let request = HTTPMessage.parse(Data(full.utf8))
        #expect(request?.body == Data("hel".utf8))
    }

    @Test("a request with no body and no Content-Length parses immediately")
    func noBodyNoContentLength() {
        let full = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        let request = HTTPMessage.parse(Data(full.utf8))
        #expect(request != nil)
        #expect(request?.body == Data())
    }

    @Test("header names are lowercased")
    func headersLowercased() {
        let full = "POST /mcp HTTP/1.1\r\nAuthorization: Bearer vf_x\r\nMCP-Protocol-Version: 2025-06-18\r\n\r\n"
        let request = HTTPMessage.parse(Data(full.utf8))
        #expect(request?.headers["authorization"] == "Bearer vf_x")
        #expect(request?.headers["mcp-protocol-version"] == "2025-06-18")
        #expect(request?.headers["Authorization"] == nil)
    }

    @Test("incomplete headers (no terminator yet) parse as nil")
    func incompleteHeaders() {
        let partial = "POST /mcp HTTP/1.1\r\nContent-Length: 5\r\n"
        #expect(HTTPMessage.parse(Data(partial.utf8)) == nil)
    }

    /// Review M4: the old "three chunks" test above never actually reaches this branch — all three
    /// chunks are shorter than the header block, so every assertion exercises the
    /// headers-incomplete path. This is the branch that matters for a real chunked POST: headers
    /// complete, `Content-Length` bytes still arriving.
    @Test("a request whose headers are already complete parses as nil until the declared body length has fully arrived")
    func bodyIncompleteAcrossChunks() {
        let head = "POST /mcp HTTP/1.1\r\nContent-Length: 10\r\n\r\n"
        let full = head + "0123456789"
        let bytes = Array(full.utf8)
        let headersOnlyNoBody = Data(bytes[0..<head.utf8.count])
        let headersPlusPartialBody = Data(bytes[0..<(head.utf8.count + 4)])
        let complete = Data(bytes)

        #expect(HTTPMessage.parse(headersOnlyNoBody) == nil)
        #expect(HTTPMessage.parse(headersPlusPartialBody) == nil)

        let request = HTTPMessage.parse(complete)
        #expect(request?.body == Data("0123456789".utf8))
    }

    @Test("a response renders the exact status line, Content-Type, Content-Length and Connection: close")
    func responseRendersExactly() {
        let body = Data(#"{"ok":true}"#.utf8)
        let rendered = HTTPMessage.write(status: 200, body: body)
        let text = String(data: rendered, encoding: .utf8)
        #expect(text == "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\nConnection: close\r\n\r\n{\"ok\":true}")
    }

    @Test("a response with no body omits Content-Type and Content-Length but still closes")
    func responseWithNoBody() {
        let rendered = HTTPMessage.write(status: 202, body: nil)
        let text = String(data: rendered, encoding: .utf8)
        #expect(text == "HTTP/1.1 202 Accepted\r\nConnection: close\r\n\r\n")
    }

    @Test("a 404 response renders the correct status text")
    func notFoundStatusText() {
        let rendered = HTTPMessage.write(status: 404, body: nil)
        let text = String(data: rendered, encoding: .utf8)
        #expect(text == "HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n")
    }

    @Test("a 413 response renders the correct status text (review C1: oversize requests)")
    func payloadTooLargeStatusText() {
        let rendered = HTTPMessage.write(status: 413, body: nil)
        let text = String(data: rendered, encoding: .utf8)
        #expect(text == "HTTP/1.1 413 Payload Too Large\r\nConnection: close\r\n\r\n")
    }

    @Test("headerTerminatorEnd finds the terminator only from the given offset onward")
    func headerTerminatorEndRespectsSearchOffset() {
        let data = Data("AAAA\r\n\r\nBBBB".utf8)
        #expect(HTTPMessage.headerTerminatorEnd(in: data, searchingFrom: 0) == 8)
        // Searching from an offset that skips past where the terminator starts finds nothing —
        // callers are responsible for resuming just before the tail, not mid-terminator.
        #expect(HTTPMessage.headerTerminatorEnd(in: data, searchingFrom: 8) == nil)
    }

    @Test("headerTerminatorEnd finds a terminator that starts exactly at the search offset")
    func headerTerminatorEndAtOffset() {
        let data = Data("AAAA\r\n\r\nBBBB".utf8)
        #expect(HTTPMessage.headerTerminatorEnd(in: data, searchingFrom: 4) == 8)
    }
}
