import CryptoKit
import Darwin
import Foundation
import Testing
import VoxFlowAudio
import VoxFlowCore
import VoxFlowDictation
import VoxFlowFiles
import VoxFlowMCP
import VoxFlowSpeech
import VoxFlowStorage
import VoxFlowTestSupport
@testable import VoxFlow

// MARK: - Skip helpers (printed reasons, no fixed sleeps)

/// Whether *any* port in the server's scan range can be bound on this machine right now. Reused
/// from `LoopbackListenerTests`' own real-socket `canBind` helper, so this asks the OS the exact
/// same way the listener itself would — same small race window that file already accepts.
private enum LoopbackAvailability {
    static let anyPortFree: Bool = {
        guard ProcessInfo.processInfo.environment["VOXFLOW_MCP_INTEGRATION"] == "1" else { return false }
        for port: UInt16 in 7331...7340 where LoopbackListenerPortScanTests.canBind(port: port) { return true }
        return false
    }()
}

/// Mirrors `VoxFlowSpeechTests.InstalledModel` (that enum is private to its own test target, so it
/// can't be imported directly): the smallest installed Whisper model under the app's real model
/// directory, or `nil` when none is installed.
private enum InstalledSpeechModel {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/VoxFlow/Models")
    static let url: URL? = ["ggml-small.bin", "ggml-large-v3-turbo.bin", "ggml-base.bin"]
        .map { directory.appendingPathComponent($0) }
        .first { FileManager.default.fileExists(atPath: $0.path) }
}

/// The same fixture `VoxFlowSpeechTests`' `RequiresModel` suite transcribes — referenced by a real
/// filesystem path (via `#filePath`) rather than an SPM resource bundle, since `VoxFlowTests` is an
/// Xcode unit-test target with no resources of its own.
private enum Fixtures {
    static var attention10sWAV: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // VoxFlowTests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("VoxFlowKit/Tests/VoxFlowSpeechTests/Fixtures/attention-10s.wav")
    }
}

// MARK: - Fakes local to this suite

private struct FixedPeerResolver: PeerResolving {
    let name: String
    let path: String
    let pid: Int32
    func resolveProcess(peerPort: UInt16, serverPort: UInt16) -> (pid: Int32, name: String, path: String)? {
        (pid: pid, name: name, path: path)
    }
}

/// Always answers "Always allow" — the integration test drives the loopback transport for real, but
/// stands in for the ST-06a *UI* panel exactly as `MCPToolRunnerTests`' fake does; Task 4's render
/// tests already cover the real panel's appearance.
private struct AlwaysAllowPresenter: MCPApprovalPresenting {
    func present(identity: MCPClientIdentity, tools: [String], canPersist: Bool) async -> MCPClientDecision { .allow }
}

private struct IntegrationHistoryKeyProvider: HistoryKeyProviding {
    func historyKey() throws -> HistoryKey { HistoryKey(key: SymmetricKey(size: .bits256), isNewlyCreated: true) }
}

// MARK: - Harness

/// Everything one test needs to drive a real `MCPServerService` (which owns a real `LoopbackListener`
/// + `MCPToolRunner`) over an actual loopback socket, plus the pieces a test wants to poke at
/// afterwards (settings for the token, the coordinator/mic to drive a fake capture, the history
/// service to seed records).
@MainActor
private struct IntegrationServer {
    let service: MCPServerService
    let settings: MCPSettings
    let coordinator: DictationCoordinator
    let controller: DictationController
    let mic: FakeMicrophone
    let historyService: HistoryService
    var port: UInt16 { service.boundPort ?? 0 }
    var token: String { settings.token }
}

@MainActor
private func makeIntegrationServer(
    fileTranscribing: any FileTranscribing = FakeFileTranscriber(),
    pathPolicy: PathPolicy? = nil,
    dictate: Bool = true, transcribeFile: Bool = true, searchHistory: Bool = true,
    framingDeadline: TimeInterval = ConnectionHandler.defaultFramingDeadline
) -> IntegrationServer {
    let settings = MCPSettings(store: InMemoryKeyValueStore(), token: FakeTokenStore(stored: "vf_integration_test_token"))
    settings.toolDictate = dictate
    settings.toolTranscribeFile = transcribeFile
    settings.toolSearchHistory = searchHistory

    let clock = FakeClock()
    let mic = FakeMicrophone()
    // Never resolves on its own (no `hold` gate opened) — exactly the shape `dictateBusyWhileActive`
    // (`MCPToolRunnerTests`) uses to keep a capture observably running for as long as a test needs.
    let transcriber = FakeDictationTranscriber(result: .empty, hold: Gate())
    let controller = DictationController(
        config: FlowBarConfig(), microphone: mic, transcriber: transcriber, inserter: FakeTextInserter(), clock: clock,
        preflight: { Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .loaded) },
        loadModel: {}, options: { TranscriptionOptions() }, onSave: { _, _ in }, copyToClipboard: { _ in }
    )
    let dictationSettings = DictationSettings(store: InMemoryKeyValueStore())
    let permissions = FakePermissions(microphone: .granted, requestResult: .granted, accessibility: true)
    let coordinator = DictationCoordinator(controller: controller, settings: dictationSettings, permissions: permissions,
                                           navigation: Navigation(), clock: clock)
    coordinator.start()

    let historyDir = TemporaryDirectory()
    let historySettings = DictationSettings(store: InMemoryKeyValueStore())
    historySettings.retentionDays = 0
    let historyService = HistoryService(url: historyDir.file("voxflow.sqlite"), settings: historySettings,
                                        keyProvider: { IntegrationHistoryKeyProvider() }, clock: clock)

    let resolvedPathPolicy = pathPolicy ?? PathPolicy(homeDirectory: TemporaryDirectory().url, allowedExtensions: ["wav"])
    let resolver = FixedPeerResolver(name: "Cursor", path: "/Applications/Cursor.app/Contents/MacOS/Cursor", pid: 4812)

    let service = MCPServerService(settings: settings, coordinator: coordinator, controller: controller, historyService: historyService,
                                   fileTranscribing: fileTranscribing, pathPolicy: resolvedPathPolicy, clock: clock,
                                   approvalPresenter: AlwaysAllowPresenter(), serverVersion: "2.0.0-integration-test", resolver: resolver,
                                   framingDeadline: framingDeadline)

    return IntegrationServer(service: service, settings: settings, coordinator: coordinator, controller: controller,
                             mic: mic, historyService: historyService)
}

/// Builds a server, starts its real `LoopbackListener`, hands it to `body`, then **awaits**
/// `stop()` before returning — success or thrown error alike — so the bound port is actually
/// released before the next `.serialized` test in this suite starts its own scan. (A `defer` here
/// could only fire an un-awaited `Task`, since `defer` bodies can't themselves suspend; that would
/// let this port linger bound into the next test.)
@MainActor
private func withIntegrationServer<T: Sendable>(
    fileTranscribing: any FileTranscribing = FakeFileTranscriber(),
    pathPolicy: PathPolicy? = nil,
    dictate: Bool = true, transcribeFile: Bool = true, searchHistory: Bool = true,
    framingDeadline: TimeInterval = ConnectionHandler.defaultFramingDeadline,
    _ body: (IntegrationServer) async throws -> T
) async throws -> T {
    let server = makeIntegrationServer(fileTranscribing: fileTranscribing, pathPolicy: pathPolicy,
                                       dictate: dictate, transcribeFile: transcribeFile, searchHistory: searchHistory,
                                       framingDeadline: framingDeadline)
    try await server.service.start()
    do {
        let result = try await body(server)
        await server.service.stop()
        return result
    } catch {
        await server.service.stop()
        throw error
    }
}

// MARK: - HTTP helpers (URLSession — status codes and decoded JSON-RPC bodies)

private enum IntegrationHTTPError: Error { case notHTTPResponse }

private func rpcRequest(port: UInt16, token: String?, origin: String? = nil, httpMethod: String = "POST",
                        method: String, params: JSONValue? = nil, id: JSONRPCID? = .number(1)) -> URLRequest {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
    request.httpMethod = httpMethod
    request.cachePolicy = .reloadIgnoringLocalCacheData
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
    if httpMethod == "POST" {
        let body = JSONRPCRequest(id: id, method: method, params: params)
        request.httpBody = try! JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    return request
}

private func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw IntegrationHTTPError.notHTTPResponse }
    return (http, data)
}

private func toolCallParams(name: String, arguments: JSONValue) -> JSONValue {
    .object(["name": .string(name), "arguments": arguments])
}

// MARK: - Raw-socket helpers (for the cap tests URLSession can't drive precisely)

private enum RawSocket {
    static func connect(port: UInt16) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return fd }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = port.bigEndian
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { close(fd); return -1 }
        // Writing to a socket the server has already reset raises SIGPIPE, which nothing in this
        // repo ignores — it would kill the whole test binary rather than fail one test. The
        // deadline test deliberately keeps writing while the server is closing under it, so every
        // raw socket here opts out (final re-review 2).
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    static func setReceiveTimeout(_ fd: Int32, milliseconds: Int) {
        var tv = timeval(tv_sec: milliseconds / 1000, tv_usec: Int32((milliseconds % 1000) * 1000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Sends every byte of `data`, blocking (subject to normal TCP flow control) until the whole
    /// buffer has been handed to the kernel or a send error occurs.
    static func sendAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.send(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                guard n > 0 else { return }
                sent += n
            }
        }
    }

    /// `true` if the peer has already closed (a `recv` within `timeoutMilliseconds` returns `0`,
    /// i.e. EOF) without ever sending a byte — how the connection-cap test tells "rejected before
    /// any byte was read" apart from "accepted and just waiting for a request".
    static func isClosedWithoutData(_ fd: Int32, timeoutMilliseconds: Int) -> Bool {
        setReceiveTimeout(fd, milliseconds: timeoutMilliseconds)
        var buffer = [UInt8](repeating: 0, count: 16)
        let n = recv(fd, &buffer, buffer.count, 0)
        if n == 0 { return true }   // orderly FIN
        // A server that closes with bytes still unread sends RST, not FIN, so the read fails
        // instead of returning 0. Both mean "the peer is gone" for these tests; only a timeout
        // (EAGAIN/EWOULDBLOCK) means "still open, just quiet" (final re-review 2).
        if n < 0, errno == ECONNRESET || errno == EPIPE { return true }
        return false
    }

    /// Reads whatever the peer sends within `timeoutMilliseconds`, stopping early once at least
    /// `minBytes` have arrived (enough to see an HTTP status line).
    static func receiveSome(_ fd: Int32, minBytes: Int, timeoutMilliseconds: Int) -> Data {
        setReceiveTimeout(fd, milliseconds: timeoutMilliseconds)
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while response.count < minBytes {
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else { break }
            response.append(contentsOf: buffer[0..<n])
        }
        return response
    }
}

// MARK: - Suite

/// Exercises the loopback MCP server end to end over a real socket — the one place these security
/// rules and the wire protocol are proven against an actual `LoopbackListener`, not just the pure
/// `MCPHTTPPolicy`/`MCPRouter`/`MCPToolRunner` unit tests. `.serialized`: each test binds its own
/// fresh port from the same 7331…7340 range, and running them one at a time (with teardown properly
/// awaited — see `withIntegrationServer`) avoids exhausting that 10-port range.
@Suite("MCP server (loopback integration)", .serialized,
       .enabled(if: LoopbackAvailability.anyPortFree, "Set VOXFLOW_MCP_INTEGRATION=1; a free loopback port is required"))
@MainActor
struct MCPServerIntegrationTests {
    // MARK: initialize → tools/list → search_history

    @Test("initialize, tools/list and a real tools/call search_history round-trip over loopback HTTP")
    func initializeToolsListAndSearchHistory() async throws {
        try await withIntegrationServer { server in
            let port = server.port
            try #require(port != 0)

            // Seed a couple of history rows the real socket call will read back.
            _ = await server.historyService.count() // forces the open to finish
            let store = try #require(server.historyService.store)
            let base = Date(timeIntervalSince1970: 1_700_000_000)
            for i in 0..<3 {
                _ = try store.insert(DictationDraft(text: "integration note \(i)", rawText: "integration note \(i)", appName: "Cursor",
                                                    style: nil, language: "en", duration: 1, createdAt: base.addingTimeInterval(TimeInterval(i))))
            }

            // 1. initialize (legacy handshake — the era real clients speak today).
            let (initResponse, initData) = try await send(rpcRequest(
                port: port, token: server.token, method: "initialize",
                params: .object(["protocolVersion": .string(MCPProtocolVersion.legacy)])))
            #expect(initResponse.statusCode == 200)
            let initRPC = try JSONDecoder().decode(JSONRPCResponse.self, from: initData)
            #expect(initRPC.result?["protocolVersion"]?.stringValue == MCPProtocolVersion.legacy)
            #expect(initRPC.result?["serverInfo"]?["name"]?.stringValue == "VoxFlow")

            // 2. notifications/initialized — a notification, answered 202 with no body.
            let (notifiedResponse, _) = try await send(rpcRequest(
                port: port, token: server.token, method: "notifications/initialized", id: nil))
            #expect(notifiedResponse.statusCode == 202)

            // 3. tools/list — all three tools enabled by default in this harness.
            let (listResponse, listData) = try await send(rpcRequest(port: port, token: server.token, method: "tools/list"))
            #expect(listResponse.statusCode == 200)
            let listRPC = try JSONDecoder().decode(JSONRPCResponse.self, from: listData)
            let toolNames = Set(listRPC.result?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? [])
            #expect(toolNames == ["transcribe_file", "dictate", "search_history"])

            // 4. tools/call search_history — a real socket round trip against a seeded temporary store.
            let (searchResponse, searchData) = try await send(rpcRequest(
                port: port, token: server.token, method: "tools/call",
                params: toolCallParams(name: "search_history", arguments: .object(["query": .string(""), "limit": .int(10)]))))
            #expect(searchResponse.statusCode == 200)
            let searchRPC = try JSONDecoder().decode(JSONRPCResponse.self, from: searchData)
            let json = try #require(searchRPC.result?["content"]?.arrayValue?.first?["text"]?.stringValue)
            struct Hit: Decodable { var text: String; var app: String?; var createdAt: String; var words: Int }
            let hits = try JSONDecoder().decode([Hit].self, from: Data(json.utf8))
            #expect(hits.count == 3)
            #expect(hits.allSatisfy { $0.app == "Cursor" })
        }
    }

    // MARK: transcribe_file (RequiresModel)

    @Test("tools/call transcribe_file over loopback HTTP transcribes the fixture with the real engine",
          .enabled(if: InstalledSpeechModel.url != nil,
                   "No Whisper model in ~/Library/Application Support/VoxFlow/Models; download one via the app or the spike"),
          .timeLimit(.minutes(3)))
    func transcribeFileOverLoopback() async throws {
        let home = TemporaryDirectory()
        let audioURL = home.file("attention-10s.wav")
        try Data(contentsOf: Fixtures.attention10sWAV).write(to: audioURL)
        let pathPolicy = PathPolicy(homeDirectory: home.url, allowedExtensions: ["wav"])

        let engine = WhisperCppEngine()
        try await engine.load(modelAt: InstalledSpeechModel.url!)
        let fileTranscribing = FileTranscriber(decoder: AudioDecoder(), engine: engine, modelID: "integration-test")

        try await withIntegrationServer(fileTranscribing: fileTranscribing, pathPolicy: pathPolicy) { server in
            let port = server.port
            try #require(port != 0)

            let (response, data) = try await send(rpcRequest(
                port: port, token: server.token, method: "tools/call",
                params: toolCallParams(name: "transcribe_file", arguments: .object(["path": .string(audioURL.path)]))))
            #expect(response.statusCode == 200)
            let rpc = try JSONDecoder().decode(JSONRPCResponse.self, from: data)
            let text = try #require(rpc.result?["content"]?.arrayValue?.first?["text"]?.stringValue)
            #expect(text.lowercased().contains("attention"))
        }
    }

    // MARK: dictate — not exercised for real (no microphone in a test run)

    @Test("tools/call dictate answers -32002 while a fake capture is already active")
    func dictateAnswersBusyOverLoopback() async throws {
        try await withIntegrationServer { server in
            let port = server.port
            try #require(port != 0)

            server.coordinator.fn(.down)
            while !server.coordinator.isHUDActive { await Task.yield() }

            let (response, data) = try await send(rpcRequest(
                port: port, token: server.token, method: "tools/call",
                params: toolCallParams(name: "dictate", arguments: .object([:]))))
            #expect(response.statusCode == 200)
            let rpc = try JSONDecoder().decode(JSONRPCResponse.self, from: data)
            #expect(rpc.error?.code == -32002)
            #expect(rpc.error?.message == "A dictation is already running.")
        }
    }

    // MARK: security surface, end to end over the real socket

    @Test("no bearer token → 401")
    func noBearerTokenIs401() async throws {
        try await withIntegrationServer { server in
            let port = server.port
            try #require(port != 0)
            let (response, _) = try await send(rpcRequest(port: port, token: nil, method: "tools/list"))
            #expect(response.statusCode == 401)
        }
    }

    @Test("GET → 405")
    func getIs405() async throws {
        try await withIntegrationServer { server in
            let port = server.port
            try #require(port != 0)
            let (response, _) = try await send(rpcRequest(port: port, token: server.token, httpMethod: "GET", method: "tools/list"))
            #expect(response.statusCode == 405)
        }
    }

    @Test("a foreign Origin → 403")
    func foreignOriginIs403() async throws {
        try await withIntegrationServer { server in
            let port = server.port
            try #require(port != 0)
            let (response, _) = try await send(rpcRequest(port: port, token: server.token, origin: "https://evil.example", method: "tools/list"))
            #expect(response.statusCode == 403)
        }
    }

    @Test("an unknown method → 404 with JSON-RPC -32601")
    func unknownMethodIs404() async throws {
        try await withIntegrationServer { server in
            let port = server.port
            try #require(port != 0)
            let (response, data) = try await send(rpcRequest(port: port, token: server.token, method: "totally/unknown"))
            #expect(response.statusCode == 404)
            let rpc = try JSONDecoder().decode(JSONRPCResponse.self, from: data)
            #expect(rpc.error?.code == -32601)
        }
    }

    @Test("a request over the 1 MB cap → 413")
    func overCapRequestIs413() async throws {
        try await withIntegrationServer { server in
            let port = server.port
            try #require(port != 0)

            let fd = RawSocket.connect(port: port)
            try #require(fd >= 0)
            defer { close(fd) }

            // Just over `HTTPMessage.maxRequestBytes` (1 MB) — deliberately not some much larger
            // size: the server stops reading the instant the cap trips, so sending no more than
            // what actually gets consumed avoids leaving unread bytes in the kernel's receive
            // buffer, which would otherwise race the server's own `cancel()` into an RST that could
            // drop the 413 response before this test ever sees it.
            let bodySize = HTTPMessage.maxRequestBytes + 8192
            var request = Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(server.token)\r\n".utf8)
            request.append(Data("Content-Type: application/json\r\nContent-Length: \(bodySize)\r\n\r\n".utf8))
            request.append(Data(repeating: UInt8(ascii: "x"), count: bodySize))

            RawSocket.sendAll(fd, request)
            let response = RawSocket.receiveSome(fd, minBytes: 12, timeoutMilliseconds: 5000)
            let statusLine = String(decoding: response.prefix(32), as: UTF8.self)
            #expect(statusLine.hasPrefix("HTTP/1.1 413"))
        }
    }

    // MARK: connection cap (16 concurrent connections — Task 2 reviews I2/C1, deferred to this task)

    @Test("the 16-connection cap: a 17th connection is closed before any byte is read")
    func seventeenthConnectionIsRejected() async throws {
        try await withIntegrationServer { server in
            let port = server.port
            try #require(port != 0)

            var fds: [Int32] = []
            defer { for fd in fds { close(fd) } }
            for _ in 0..<17 {
                let fd = RawSocket.connect(port: port)
                try #require(fd >= 0)
                fds.append(fd)
            }

            // A real, bounded receive timeout — not a fixed sleep — on every socket: an accepted
            // connection that's simply waiting for a request never sends anything, so this always
            // waits the full timeout for those; a connection the cap rejected is closed (recv
            // returns 0) as soon as its accept has run.
            //
            // The assertion is "at least one was refused", not "exactly one". `accept()` is
            // dispatched per connection through a `Task`, so the order in which the 17 accepts run
            // is not guaranteed and neither is how many have run by the time the first socket is
            // polled. Over sixteen connections **must** be refused; pinning the count to exactly
            // one would make a loaded machine fail a server that is behaving correctly (Task 5
            // review). One second per socket keeps the refusal observable under CI load.
            let closedCount = fds.filter { RawSocket.isClosedWithoutData($0, timeoutMilliseconds: 1000) }.count
            #expect(closedCount >= 1)   // the cap is enforced: 17 connections cannot all be served
            #expect(closedCount < 17)   // …and it did not refuse everything, which would mean the cap is wrong
        }
    }

    // MARK: the framing deadline (final review F2)

    @Test("a peer that never completes a request is closed by the framing deadline, no matter how it drips bytes")
    func framingDeadlineClosesAnIncompleteRequest() async throws {
        // The deadline is injected short so this needs no 30 s wait. What it proves is the property
        // the fix is about: the deadline is *absolute*, so arriving bytes cannot postpone it. The
        // socket drips a byte every 50 ms for well over the deadline and must still be closed —
        // before the fix, each byte refreshed the timer and the connection lived forever, letting
        // sixteen such peers lock out every real client pre-auth.
        let deadline: TimeInterval = 0.5
        try await withIntegrationServer(framingDeadline: deadline) { server in
            let port = server.port
            try #require(port != 0)

            let fd = RawSocket.connect(port: port)
            try #require(fd >= 0)
            defer { close(fd) }

            // A request line and headers that will never be terminated, then a slow drip.
            RawSocket.sendAll(fd, Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n".utf8))
            let start = ContinuousClock.now
            var closed = false
            while ContinuousClock.now - start < .seconds(deadline * 6) {
                if RawSocket.isClosedWithoutData(fd, timeoutMilliseconds: 50) { closed = true; break }
                RawSocket.sendAll(fd, Data("x".utf8))   // keep dripping — this must not buy more time
            }
            #expect(closed, "the framing deadline never fired: a byte-dripping peer held its slot")
        }
    }
}
