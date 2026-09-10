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

/// Task 2 re-review round 2, N3: the size caps, the `413` decision, and the scan-offset advance
/// were already a pure step over accumulated `Data` — `HTTPFraming` is that seam made explicit, and
/// (unlike the idle timer / connection cap, which need a real socket) it's unit-tested without one.
@Suite("HTTPFraming")
struct HTTPFramingTests {
    @Test("a header block just under the 16 KB cap completes")
    func headerUnderCapCompletes() {
        var framing = HTTPFraming()
        let padding = String(repeating: "a", count: 16_000)
        let head = "POST /mcp HTTP/1.1\r\nContent-Length: 0\r\nX-Pad: \(padding)\r\n\r\n"
        #expect(head.utf8.count < HTTPMessage.maxHeaderBytes)

        let step = framing.advance(appending: Data(head.utf8))
        guard case .complete(let request) = step else {
            Issue.record("expected .complete, got \(step)")
            return
        }
        #expect(request.method == "POST")
        #expect(request.path == "/mcp")
    }

    @Test("a header block over the 16 KB cap, with no terminator yet, is tooLarge")
    func headerOverCapIsTooLarge() {
        var framing = HTTPFraming()
        // No `\r\n\r\n` anywhere in this — the terminator search must still be running.
        let oversized = Data(repeating: 0x41, count: HTTPMessage.maxHeaderBytes + 1)
        #expect(framing.advance(appending: oversized) == .tooLarge)
    }

    @Test("a body that keeps the whole request comfortably under the 1 MB cap completes")
    func bodyUnderCapCompletes() {
        var framing = HTTPFraming()
        let bodyLength = HTTPMessage.maxRequestBytes - 1_000
        let head = "POST /mcp HTTP/1.1\r\nContent-Length: \(bodyLength)\r\n\r\n"
        #expect(head.utf8.count + bodyLength < HTTPMessage.maxRequestBytes)

        #expect(framing.advance(appending: Data(head.utf8)) == .needMore)
        let step = framing.advance(appending: Data(repeating: 0x62, count: bodyLength))
        guard case .complete(let request) = step else {
            Issue.record("expected .complete, got \(step)")
            return
        }
        #expect(request.body.count == bodyLength)
    }

    @Test("a body that pushes the whole request over the 1 MB cap is tooLarge")
    func bodyOverCapIsTooLarge() {
        var framing = HTTPFraming()
        let head = "POST /mcp HTTP/1.1\r\nContent-Length: \(HTTPMessage.maxRequestBytes)\r\n\r\n"
        #expect(framing.advance(appending: Data(head.utf8)) == .needMore)
        // head.count + this already exceeds the cap, regardless of the declared Content-Length.
        let step = framing.advance(appending: Data(repeating: 0x63, count: HTTPMessage.maxRequestBytes))
        #expect(step == .tooLarge)
    }

    /// N3's "assert via a counter": proves the header is decoded exactly once, no matter how many
    /// chunks the body — or even the header itself — arrives in. This is the actual fix for N2 (the
    /// re-review found `ConnectionHandler` re-parsing the whole header block on every chunk of a
    /// streaming body, a pre-auth CPU cost an unauthenticated peer could force repeatedly).
    @Test("a request split across many single-byte chunks completes exactly once, with the header decoded exactly once")
    func splitAcrossManyChunksParsesHeaderOnce() {
        var framing = HTTPFraming()
        let full = "POST /mcp HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello"
        var completions = 0
        for byte in Array(full.utf8) {
            if case .complete = framing.advance(appending: Data([byte])) {
                completions += 1
            }
        }
        #expect(completions == 1)
        #expect(framing.headerParseCount == 1)
    }

    @Test("a header block whose terminator arrived but that never parses is decoded exactly once (re-review B2)")
    func malformedHeaderDecodedOnce() {
        // A single-token request line: the terminator is there, so framing keeps saying `needMore`,
        // but appending body bytes can never make it valid. Before the fix every chunk re-decoded
        // the whole header block, which a peer could turn into unbounded CPU work pre-auth.
        var framing = HTTPFraming()
        #expect(framing.advance(appending: Data("GARBAGE\r\n\r\n".utf8)) == .needMore)
        for _ in 0..<500 {
            #expect(framing.advance(appending: Data("x".utf8)) == .needMore)
        }
        #expect(framing.headerDecodeAttempts == 1)
        #expect(framing.headerParseCount == 0)
    }

    @Test("an oversized header block that arrives in one read with its terminator is still tooLarge (re-review B2)")
    func oversizedHeaderWithTerminatorInOneRead() {
        // The cap used to be checked only while the terminator was missing, so one big read that
        // happened to contain it slipped past the 16 KB limit entirely.
        let padding = String(repeating: "a", count: HTTPMessage.maxHeaderBytes + 1)
        let request = "POST /mcp HTTP/1.1\r\nx-pad: \(padding)\r\n\r\n"
        var framing = HTTPFraming()
        #expect(framing.advance(appending: Data(request.utf8)) == .tooLarge)
    }

    @Test("a tooLarge step never produces a request")
    func tooLargeNeverCompletes() {
        var framing = HTTPFraming()
        let step = framing.advance(appending: Data(repeating: 0x41, count: HTTPMessage.maxRequestBytes + 1))
        #expect(step == .tooLarge)
        if case .complete = step {
            Issue.record("a tooLarge request must never also report complete")
        }
    }
}
