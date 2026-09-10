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
}
