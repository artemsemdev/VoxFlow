import Foundation
import VoxFlowMCP

/// The HTTP/1.1 request parser and response writer for the loopback MCP listener. Pure — no
/// sockets — so `LoopbackListener`'s `ConnectionHandler` (via `HTTPFraming`, below) feeds it
/// accumulated bytes and this stays fully unit-testable.
enum HTTPMessage {
    private static let headerTerminator = Array("\r\n\r\n".utf8)

    /// Ruling (Task 2 review, C1): framing happens before any token/approval check, so every byte
    /// is attacker-controlled by any unprivileged local process. These bound what `ConnectionHandler`
    /// will buffer: the header block (everything up to `\r\n\r\n`) is capped at 16 KB, and the whole
    /// request (headers + body) at 1 MB. Exceeding either answers `413` and closes.
    static let maxHeaderBytes = 16 * 1024
    static let maxRequestBytes = 1 * 1024 * 1024

    /// The request line and headers, decoded once the terminator has been found ending at
    /// `headerEnd` (the index just past `\r\n\r\n`, i.e. where the body starts). Shared by
    /// `parse(_:)` (one-shot, whole-buffer use) and `HTTPFraming` (incremental use across many
    /// chunks, which — Task 2 re-review round 2, N2 — decodes this exactly once and caches it,
    /// rather than re-running `parseHeader` from scratch on every chunk of a streaming body).
    struct ParsedHeader: Equatable {
        var method: String
        var path: String
        var headers: [String: String]
        var headerEnd: Data.Index
        var contentLength: Int
    }

    /// Attempts to parse one HTTP request from `data` accumulated so far from a connection.
    /// `nil` while the header block (`\r\n\r\n`) hasn't fully arrived, or while fewer than
    /// `Content-Length` body bytes have arrived; extra bytes beyond `Content-Length` are ignored
    /// (truncated to the declared length). Header names are lowercased. One-shot: re-scans `data`
    /// from the start every call, which is fine for a whole buffer already in hand (tests, or any
    /// other one-off caller) but not for framing a connection's bytes incrementally — see
    /// `HTTPFraming` for that.
    static func parse(_ data: Data) -> MCPHTTPRequest? {
        guard let headerEnd = headerTerminatorEnd(in: data, searchingFrom: data.startIndex) else { return nil }
        guard let header = parseHeader(data, headerEnd: headerEnd) else { return nil }
        return request(from: header, data: data)
    }

    /// Decodes the request line and header lines given that the terminator has already been found
    /// (as `headerTerminatorEnd` would report it). `nil` if the request line has fewer than two
    /// space-separated tokens, or the header block isn't valid UTF-8.
    static func parseHeader(_ data: Data, headerEnd: Data.Index) -> ParsedHeader? {
        guard let headerTextEnd = data.index(headerEnd, offsetBy: -headerTerminator.count, limitedBy: data.startIndex) else {
            return nil // headerEnd claimed to be past a 4-byte terminator but isn't; malformed input.
        }
        guard let headerText = String(data: data[data.startIndex..<headerTextEnd], encoding: .utf8) else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        return ParsedHeader(method: method, path: path, headers: headers, headerEnd: headerEnd, contentLength: contentLength)
    }

    /// Assembles the final request once `header.contentLength` bytes of body have arrived in
    /// `data`; `nil` if they haven't yet.
    static func request(from header: ParsedHeader, data: Data) -> MCPHTTPRequest? {
        let bodyStart = header.headerEnd
        guard header.contentLength > 0 else {
            return MCPHTTPRequest(method: header.method, path: header.path, headers: header.headers, body: Data())
        }
        guard data.distance(from: bodyStart, to: data.endIndex) >= header.contentLength else { return nil }
        let bodyEnd = data.index(bodyStart, offsetBy: header.contentLength)
        return MCPHTTPRequest(method: header.method, path: header.path, headers: header.headers, body: Data(data[bodyStart..<bodyEnd]))
    }

    /// Renders an HTTP/1.1 response: status line, then (when `body` is present) `Content-Type:
    /// application/json` and `Content-Length`, always `Connection: close` (no keep-alive — MCP's
    /// one-request-per-POST model doesn't need it).
    static func write(status: Int, body: Data?) -> Data {
        var lines = ["HTTP/1.1 \(status) \(statusText(status))"]
        if let body {
            lines.append("Content-Type: application/json")
            lines.append("Content-Length: \(body.count)")
        }
        lines.append("Connection: close")
        var response = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        if let body { response.append(body) }
        return response
    }

    private static func statusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        default: return "Error"
        }
    }

    /// The index just past the first `\r\n\r\n` in `data`, searching only from `searchFrom`
    /// onward — lets a caller accumulating bytes across many chunks (`HTTPFraming`) remember how
    /// far it has already scanned and resume there, rather than re-scanning the whole buffer from
    /// the start on every chunk (Task 2 review, C1: that rescan is quadratic in the number of
    /// chunks an unauthenticated peer can send before hitting `maxHeaderBytes`). A caller that
    /// hasn't found the terminator yet should pass back `max(data.count - 3, 0)` as the next
    /// `searchFrom`, so a terminator split across a chunk boundary is still found.
    static func headerTerminatorEnd(in data: Data, searchingFrom searchFrom: Data.Index) -> Data.Index? {
        firstRange(of: headerTerminator, in: data, from: searchFrom)?.upperBound
    }

    /// The first occurrence of `pattern` in `data` at or after `from` (defaulting to the start), or
    /// `nil`. `Data.firstRange(of:)` isn't available on every toolchain this targets, so this is
    /// spelled out directly.
    private static func firstRange(of pattern: [UInt8], in data: Data, from: Data.Index? = nil) -> Range<Data.Index>? {
        guard !pattern.isEmpty, data.count >= pattern.count else { return nil }
        var index = from ?? data.startIndex
        if index < data.startIndex { index = data.startIndex }
        let searchEnd = data.index(data.endIndex, offsetBy: -(pattern.count - 1))
        while index < searchEnd {
            let candidateEnd = data.index(index, offsetBy: pattern.count)
            if data[index..<candidateEnd].elementsEqual(pattern) {
                return index..<candidateEnd
            }
            index = data.index(after: index)
        }
        return nil
    }
}

/// A pure, socket-free state machine that frames one HTTP request out of the byte chunks a
/// connection hands it over time. Extracted from `ConnectionHandler` (Task 2 re-review round 2,
/// N2/N3):
///
/// - **N2**: once the header terminator is found, `advance(appending:)` decodes it via
///   `HTTPMessage.parseHeader` exactly once and caches the result — a peer dripping a large body
///   one byte at a time no longer forces a full header re-decode (string conversion, line split,
///   header-dictionary rebuild) on every single byte, which — landing on the one shared transport
///   queue every connection uses — was a pre-auth CPU DoS one layer up from the buffer-size Critical.
/// - **N3**: the size caps, the `413` decision, and the scan-offset advance were already a pure step
///   over accumulated `Data` (the seam `headerTerminatorEnd` proved it); this type *is* that seam,
///   so it — unlike the idle timer and the connection cap, which need a real `NWConnection` — is
///   unit-tested without a socket.
struct HTTPFraming {
    enum Step: Equatable {
        case needMore
        case tooLarge
        case complete(MCPHTTPRequest)
    }

    private var data = Data()
    private var searchFrom = 0
    private var header: HTTPMessage.ParsedHeader?
    /// Where the header block ends, remembered once found. Re-review B2: without this the whole
    /// header block was re-decoded on every body chunk whenever `parseHeader` failed.
    private var headerEnd: Data.Index?
    /// A header block that arrived complete but would not parse. Appending body bytes can never
    /// make it valid, so the outcome is remembered instead of being recomputed per chunk — the same
    /// pre-auth CPU exhaustion N2 fixed, on the malformed-header path.
    private var headerMalformed = false

    /// Test-only signal (N3's "assert via a counter"): how many times the header block has
    /// actually been decoded. Must stay `1` no matter how many chunks arrive after the terminator.
    private(set) var headerParseCount = 0
    /// Test-only signal for re-review B2: how many times decoding was *attempted*, successful or
    /// not. Must stay `1` even for a header block that never parses, or a peer can force an
    /// unbounded number of re-decodes by dripping a body.
    private(set) var headerDecodeAttempts = 0

    init() {}

    /// Feeds one more chunk in; call once per `NWConnection.receive` completion (an empty/no chunk
    /// is a harmless no-op append, useful for re-checking state without new bytes).
    mutating func advance(appending chunk: Data) -> Step {
        if !chunk.isEmpty { data.append(chunk) }
        guard data.count <= HTTPMessage.maxRequestBytes else { return .tooLarge }

        if headerMalformed { return .needMore }

        if headerEnd == nil {
            guard let end = HTTPMessage.headerTerminatorEnd(in: data, searchingFrom: searchFrom) else {
                guard data.count <= HTTPMessage.maxHeaderBytes else { return .tooLarge }
                // Resume just before the tail next time, so a terminator split across a chunk
                // boundary is still found — never re-scan bytes already searched.
                searchFrom = max(data.count - 3, 0)
                return .needMore
            }
            // Re-review B2: the cap has to be judged against the header block itself, not only
            // against "no terminator yet" — a single oversized read that happens to contain the
            // terminator used to slip past it entirely.
            guard data.distance(from: data.startIndex, to: end) <= HTTPMessage.maxHeaderBytes else { return .tooLarge }
            headerEnd = end
        }

        if header == nil, let headerEnd {
            headerDecodeAttempts += 1
            guard let parsed = HTTPMessage.parseHeader(data, headerEnd: headerEnd) else {
                // Malformed request line/headers even though the terminator arrived — matches
                // `HTTPMessage.parse`'s own behavior of treating this as "not yet complete" rather
                // than a hard failure; the idle timeout (`ConnectionHandler`'s job, not this
                // type's) is what eventually closes a connection stuck here. Decided once.
                headerMalformed = true
                return .needMore
            }
            header = parsed
            headerParseCount += 1
        }

        guard let header else { return .needMore } // unreachable (just assigned above), kept for exhaustiveness
        guard let request = HTTPMessage.request(from: header, data: data) else { return .needMore }
        return .complete(request)
    }
}
