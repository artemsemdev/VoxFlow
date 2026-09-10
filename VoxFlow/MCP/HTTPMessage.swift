import Foundation
import VoxFlowMCP

/// The HTTP/1.1 request parser and response writer for the loopback MCP listener. Pure — no
/// sockets — so `LoopbackListener`'s `ConnectionHandler` feeds it accumulated bytes and this stays
/// fully unit-testable.
enum HTTPMessage {
    private static let headerTerminator = Array("\r\n\r\n".utf8)

    /// Attempts to parse one HTTP request from `data` accumulated so far from a connection.
    /// `nil` while the header block (`\r\n\r\n`) hasn't fully arrived, or while fewer than
    /// `Content-Length` body bytes have arrived; extra bytes beyond `Content-Length` are ignored
    /// (truncated to the declared length). Header names are lowercased.
    static func parse(_ data: Data) -> MCPHTTPRequest? {
        guard let headerEnd = firstRange(of: headerTerminator, in: data) else { return nil }
        guard let headerText = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else { return nil }

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

        let bodyStart = headerEnd.upperBound
        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        guard contentLength > 0 else {
            return MCPHTTPRequest(method: method, path: path, headers: headers, body: Data())
        }
        guard data.distance(from: bodyStart, to: data.endIndex) >= contentLength else { return nil }
        let bodyEnd = data.index(bodyStart, offsetBy: contentLength)
        return MCPHTTPRequest(method: method, path: path, headers: headers, body: Data(data[bodyStart..<bodyEnd]))
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
        default: return "Error"
        }
    }

    /// The first occurrence of `pattern` in `data`, or `nil`. `Data.firstRange(of:)` isn't
    /// available on every toolchain this targets, so this is spelled out directly.
    private static func firstRange(of pattern: [UInt8], in data: Data) -> Range<Data.Index>? {
        guard !pattern.isEmpty, data.count >= pattern.count else { return nil }
        var index = data.startIndex
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
