import CryptoKit
import Foundation
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowDictation
import VoxFlowFiles
import VoxFlowMCP
import VoxFlowStorage
import VoxFlowTestSupport
@testable import VoxFlow

private struct FakeMCPHistoryKeyProvider: HistoryKeyProviding {
    func historyKey() throws -> HistoryKey { HistoryKey(key: SymmetricKey(size: .bits256), isNewlyCreated: true) }
}

/// Holds a stable key until `rotate()` is called — lets a test insert a row under one key, rotate,
/// then `reopen()` `HistoryService` under a different one: same trick `DictationStoreTests` uses to
/// produce a genuinely unreadable row (the store itself stays `.ready`; only that one row decodes to
/// nothing) without going through a whole-service failure like "key lost".
private final class RotatingKeyProvider: HistoryKeyProviding, Sendable {
    private let key: Mutex<SymmetricKey>
    init() { key = Mutex(SymmetricKey(size: .bits256)) }
    func historyKey() throws -> HistoryKey { HistoryKey(key: key.withLock { $0 }, isNewlyCreated: false) }
    func rotate() { key.withLock { $0 = SymmetricKey(size: .bits256) } }
}

/// Records every `present(identity:tools:)` call and answers a scripted decision — `MCPToolRunner`'s
/// approval seam (`MCPApprovalPresenting`) is defined in `MCPToolRunner.swift`; Task 4 supplies the
/// real SwiftUI panel, this is the test double.
private final class FakeApprovalPresenter: MCPApprovalPresenting, Sendable {
    private struct State { var decision: MCPClientDecision; var calls: [(identity: MCPClientIdentity, tools: [String])] = [] }
    private let state: Mutex<State>

    init(decision: MCPClientDecision) { state = Mutex(State(decision: decision)) }

    var callCount: Int { state.withLock { $0.calls.count } }
    var lastCall: (identity: MCPClientIdentity, tools: [String])? { state.withLock { $0.calls.last } }

    func present(identity: MCPClientIdentity, tools: [String]) async -> MCPClientDecision {
        state.withLock { $0.calls.append((identity, tools)) }
        return state.withLock { $0.decision }
    }
}

private struct DecodedHit: Decodable, Equatable {
    var text: String
    var app: String?
    var createdAt: String
    var words: Int
}

@Suite("MCPToolRunner", .timeLimit(.minutes(1)))
@MainActor
struct MCPToolRunnerTests {
    // MARK: fixtures

    func makeSettings(dictate: Bool = true, transcribeFile: Bool = true, searchHistory: Bool = true) -> MCPSettings {
        let settings = MCPSettings(store: InMemoryKeyValueStore(), token: FakeTokenStore(stored: "vf_test_token"))
        settings.toolDictate = dictate
        settings.toolTranscribeFile = transcribeFile
        settings.toolSearchHistory = searchHistory
        return settings
    }

    func makeDictation(clock: FakeClock, transcriber: FakeDictationTranscriber, mic: FakeMicrophone = FakeMicrophone())
        -> (DictationCoordinator, DictationController) {
        let controller = DictationController(config: FlowBarConfig(), microphone: mic, transcriber: transcriber, inserter: FakeTextInserter(), clock: clock,
                                             preflight: { Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .loaded) },
                                             loadModel: {}, options: { TranscriptionOptions() }, onSave: { _, _ in }, copyToClipboard: { _ in })
        let dictationSettings = DictationSettings(store: InMemoryKeyValueStore())
        let permissions = FakePermissions(microphone: .granted, requestResult: .granted, accessibility: true)
        let coordinator = DictationCoordinator(controller: controller, settings: dictationSettings, permissions: permissions,
                                               navigation: Navigation(), clock: clock)
        coordinator.start()
        return (coordinator, controller)
    }

    func makeEnabledHistory() -> HistoryService {
        let dir = TemporaryDirectory()
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        settings.retentionDays = 0
        return HistoryService(url: dir.file("voxflow.sqlite"), settings: settings, keyProvider: { FakeMCPHistoryKeyProvider() }, clock: FakeClock())
    }

    /// Same trick `HistoryServiceTests.databaseNilWhenFileUnopenable` uses: a file sits where a
    /// parent directory needs to be, so `VoxFlowDatabase.init(url:)`'s `createDirectory` fails and
    /// the open never succeeds — `status` ends up `.disabled(reason:)`. Forces the open (`ready()`)
    /// *inside* this helper, before `dir` (a local `TemporaryDirectory`) goes out of scope and
    /// deletes the blocker file on `deinit` — opening is lazy, so doing this in the caller instead
    /// would race the directory being removed before the open ever runs.
    func makeDisabledHistory() async throws -> HistoryService {
        let dir = TemporaryDirectory()
        let blocker = dir.file("blocker")
        try Data().write(to: blocker)
        let url = blocker.appendingPathComponent("nested").appendingPathComponent("voxflow.sqlite")
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        let service = HistoryService(url: url, settings: settings, keyProvider: { FakeMCPHistoryKeyProvider() }, clock: FakeClock())
        await service.ready()
        return service
    }

    func makeRunner(settings: MCPSettings? = nil, coordinator: DictationCoordinator, controller: DictationController,
                    historyService: HistoryService? = nil, fileTranscribing: any FileTranscribing = FakeFileTranscriber(),
                    pathPolicy: PathPolicy? = nil, clock: any MonotonicClock,
                    clientStore: MCPClientStore? = nil, approvalPresenter: any MCPApprovalPresenting = FakeApprovalPresenter(decision: .allow))
        throws -> (MCPToolRunner, MCPSettings) {
        let resolvedSettings = settings ?? makeSettings()
        let resolvedHistory = historyService ?? makeEnabledHistory()
        let resolvedPathPolicy = pathPolicy ?? PathPolicy(homeDirectory: TemporaryDirectory().url, allowedExtensions: ["wav"])
        let resolvedStore = try clientStore ?? MCPClientStore(database: VoxFlowDatabase.inMemory())
        let runner = MCPToolRunner(settings: resolvedSettings, coordinator: coordinator, controller: controller,
                                   historyService: resolvedHistory, fileTranscribing: fileTranscribing, pathPolicy: resolvedPathPolicy,
                                   clock: clock, clientStore: resolvedStore, approvalPresenter: approvalPresenter, serverVersion: "2.0.0-test")
        return (runner, resolvedSettings)
    }

    func toolCallRequest(name: String, arguments: JSONValue, token: String, id: JSONRPCID = .number(1)) -> MCPHTTPRequest {
        let rpc = JSONRPCRequest(id: id, method: "tools/call", params: .object(["name": .string(name), "arguments": arguments]))
        let body = try! JSONEncoder().encode(rpc)
        return MCPHTTPRequest(method: "POST", path: "/mcp", headers: ["authorization": "Bearer \(token)"], body: body)
    }

    func decode(_ body: Data?) throws -> JSONRPCResponse {
        try JSONDecoder().decode(JSONRPCResponse.self, from: try #require(body))
    }

    func text(from result: JSONValue?) -> String? {
        result?["content"]?.arrayValue?.first?["text"]?.stringValue
    }

    let identity = MCPClientIdentity(name: "Cursor", path: "/Applications/Cursor.app/Contents/MacOS/Cursor", pid: 123)

    // MARK: transcribe_file

    @Test("transcribe_file with an allowed path returns the rendered text")
    func transcribeFileText() async throws {
        let home = TemporaryDirectory()
        let audioURL = home.file("memo.wav")
        try Data().write(to: audioURL)
        let policy = PathPolicy(homeDirectory: home.url, allowedExtensions: ["wav"])
        let fake = FakeFileTranscriber()
        let segment = try #require(TranscriptSegment(start: 0, end: 1, text: "hello there"))
        let document = TranscriptDocument(sourceURL: audioURL, transcript: Transcript(segments: [segment], language: "en"),
                                          modelID: "base", audioDuration: 1, processingTime: 0.2, createdAt: Date(timeIntervalSince1970: 0))
        await fake.script(audioURL, .document(document))

        let (coordinator, controller) = makeDictation(clock: FakeClock(), transcriber: FakeDictationTranscriber(result: .empty))
        let (runner, settings) = try makeRunner(coordinator: coordinator, controller: controller, fileTranscribing: fake,
                                                pathPolicy: policy, clock: FakeClock())

        let request = toolCallRequest(name: "transcribe_file", arguments: .object(["path": .string(audioURL.path)]), token: settings.token)
        let (status, body) = await runner.handle(request, peer: identity)
        #expect(status == 200)
        let response = try decode(body)
        #expect(text(from: response.result)?.contains("hello there") == true)
    }

    @Test("transcribe_file with format: srt returns SRT (a --> timecode line)")
    func transcribeFileSRT() async throws {
        let home = TemporaryDirectory()
        let audioURL = home.file("memo.wav")
        try Data().write(to: audioURL)
        let policy = PathPolicy(homeDirectory: home.url, allowedExtensions: ["wav"])
        let fake = FakeFileTranscriber()
        let segment = try #require(TranscriptSegment(start: 0, end: 1.5, text: "hello there"))
        let document = TranscriptDocument(sourceURL: audioURL, transcript: Transcript(segments: [segment], language: "en"),
                                          modelID: "base", audioDuration: 1.5, processingTime: 0.2, createdAt: Date(timeIntervalSince1970: 0))
        await fake.script(audioURL, .document(document))

        let (coordinator, controller) = makeDictation(clock: FakeClock(), transcriber: FakeDictationTranscriber(result: .empty))
        let (runner, settings) = try makeRunner(coordinator: coordinator, controller: controller, fileTranscribing: fake,
                                                pathPolicy: policy, clock: FakeClock())

        let request = toolCallRequest(name: "transcribe_file", arguments: .object(["path": .string(audioURL.path), "format": .string("srt")]),
                                      token: settings.token)
        let (status, body) = await runner.handle(request, peer: identity)
        #expect(status == 200)
        let response = try decode(body)
        #expect(text(from: response.result)?.contains(" --> ") == true)
    }

    @Test("transcribe_file with /etc/passwd returns -32602 and the exact PathPolicy message")
    func transcribeFileOutsidePolicyPath() async throws {
        let home = TemporaryDirectory()
        let policy = PathPolicy(homeDirectory: home.url, allowedExtensions: ["wav"])
        let (coordinator, controller) = makeDictation(clock: FakeClock(), transcriber: FakeDictationTranscriber(result: .empty))
        let (runner, settings) = try makeRunner(coordinator: coordinator, controller: controller, pathPolicy: policy, clock: FakeClock())

        let request = toolCallRequest(name: "transcribe_file", arguments: .object(["path": .string("/etc/passwd")]), token: settings.token)
        let (status, body) = await runner.handle(request, peer: identity)
        let response = try decode(body)
        #expect(status == 200)
        #expect(response.error?.code == -32602)
        #expect(response.error?.message == PathPolicy.Rejection.outsideHome.message)
    }

    @Test("a transcription failure returns -32603 carrying the engine message")
    func transcribeFileEngineFailure() async throws {
        let home = TemporaryDirectory()
        let audioURL = home.file("memo.wav")
        try Data().write(to: audioURL)
        let policy = PathPolicy(homeDirectory: home.url, allowedExtensions: ["wav"])
        let fake = FakeFileTranscriber()
        let engineError = FileTranscriptionError.engineFailed("boom")
        await fake.script(audioURL, .failure(engineError))

        let (coordinator, controller) = makeDictation(clock: FakeClock(), transcriber: FakeDictationTranscriber(result: .empty))
        let (runner, settings) = try makeRunner(coordinator: coordinator, controller: controller, fileTranscribing: fake,
                                                pathPolicy: policy, clock: FakeClock())

        let request = toolCallRequest(name: "transcribe_file", arguments: .object(["path": .string(audioURL.path)]), token: settings.token)
        let (status, body) = await runner.handle(request, peer: identity)
        let response = try decode(body)
        #expect(status == 200)
        #expect(response.error?.code == -32603)
        #expect(response.error?.message == String(describing: engineError))
    }

    // MARK: dictate

    @Test("dictate while a dictation is already running (isHUDActive) → -32002 with the exact copy")
    func dictateBusyWhileActive() async throws {
        let clock = FakeClock()
        let (coordinator, controller) = makeDictation(clock: clock, transcriber: FakeDictationTranscriber(result: .empty, hold: Gate()))
        coordinator.fn(.down)
        while !coordinator.isHUDActive { await Task.yield() }
        let (runner, settings) = try makeRunner(coordinator: coordinator, controller: controller, clock: clock)

        let request = toolCallRequest(name: "dictate", arguments: .object([:]), token: settings.token)
        let (status, body) = await runner.handle(request, peer: identity)
        let response = try decode(body)
        #expect(status == 200)
        #expect(response.error?.code == -32002)
        #expect(response.error?.message == "A dictation is already running.")
    }

    @Test("dictate while paused → -32002 with the exact paused copy")
    func dictateBusyWhilePaused() async throws {
        let clock = FakeClock()
        let (coordinator, controller) = makeDictation(clock: clock, transcriber: FakeDictationTranscriber(result: .empty))
        coordinator.pause(for: 3600)
        while coordinator.pausedUntil == nil { await Task.yield() }
        let (runner, settings) = try makeRunner(coordinator: coordinator, controller: controller, clock: clock)

        let request = toolCallRequest(name: "dictate", arguments: .object([:]), token: settings.token)
        let (status, body) = await runner.handle(request, peer: identity)
        let response = try decode(body)
        #expect(status == 200)
        #expect(response.error?.code == -32002)
        #expect(response.error?.message == "Dictation is paused.")
    }

    @Test("dictate happy path: starts a capture through the coordinator and returns the result's text")
    func dictateHappyPath() async throws {
        let clock = FakeClock()
        let mic = FakeMicrophone()
        let transcriber = FakeDictationTranscriber(result: DictationResult(text: "hello from mcp", rawText: "hello from mcp",
                                                                            segments: [], language: nil, duration: 1, lowConfidence: false))
        let (coordinator, controller) = makeDictation(clock: clock, transcriber: transcriber, mic: mic)
        let (runner, settings) = try makeRunner(coordinator: coordinator, controller: controller, clock: clock)

        let request = toolCallRequest(name: "dictate", arguments: .object([:]), token: settings.token)
        let task = Task { await runner.handle(request, peer: identity) }
        await mic.waitUntilCapturing()
        mic.emit(rms: 0.3, seconds: 1)
        await transcriber.waitUntilReceived(1)
        await clock.waitForSleepers(3)              // cap + silence (FlowBarMachine) + this dictate call's own timeout
        await clock.advance(by: 3)                   // FlowBarConfig.silenceStop default
        let (status, body) = await task.value
        let response = try decode(body)
        #expect(status == 200)
        #expect(text(from: response.result) == "hello from mcp")
    }

    @Test("dictate: no result before FlowBarConfig.maxDuration + .processingTimeout (on the injected clock) → -32003")
    func dictateTimesOut() async throws {
        let clock = FakeClock()
        let transcriber = FakeDictationTranscriber(result: .empty, hold: Gate())     // never returns
        let (coordinator, controller) = makeDictation(clock: clock, transcriber: transcriber)
        let (runner, settings) = try makeRunner(coordinator: coordinator, controller: controller, clock: clock)

        let request = toolCallRequest(name: "dictate", arguments: .object([:]), token: settings.token)
        let task = Task { await runner.handle(request, peer: identity) }
        await clock.waitForSleepers(3)               // cap + silence (FlowBarMachine) + this dictate call's own timeout
        await clock.advance(by: 920)                  // default maxDuration(900) + processingTimeout(20)
        let (status, body) = await task.value
        let response = try decode(body)
        #expect(status == 200)
        #expect(response.error?.code == -32003)
        #expect(response.error?.message == "Dictation timed out.")
    }

    // MARK: search_history

    @Test("search_history with history disabled → -32004 and the readable reason")
    func searchHistoryDisabled() async throws {
        let history = try await makeDisabledHistory()
        guard case .disabled(let reason) = history.status else { Issue.record("expected .disabled"); return }
        let expectedMessage = HistoryViewModel.readableReason(reason)

        let (coordinator, controller) = makeDictation(clock: FakeClock(), transcriber: FakeDictationTranscriber(result: .empty))
        let (runner, settings) = try makeRunner(coordinator: coordinator, controller: controller, historyService: history, clock: FakeClock())

        let request = toolCallRequest(name: "search_history", arguments: .object(["query": .string("")]), token: settings.token)
        let (status, body) = await runner.handle(request, peer: identity)
        let response = try decode(body)
        #expect(status == 200)
        #expect(response.error?.code == -32004)
        #expect(response.error?.message == expectedMessage)
    }

    @Test("search_history: hits render text/app/createdAt/words, and limit is respected")
    func searchHistoryRendersHitsAndRespectsLimit() async throws {
        let history = makeEnabledHistory()
        _ = await history.count()   // force the open to finish
        let store = try #require(history.store)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<5 {
            _ = try store.insert(DictationDraft(text: "note \(i)", rawText: "note \(i)", appName: "Mail", style: nil, language: "en",
                                                duration: 1, createdAt: base.addingTimeInterval(TimeInterval(i))))
        }

        let (coordinator, controller) = makeDictation(clock: FakeClock(), transcriber: FakeDictationTranscriber(result: .empty))
        let (runner, settings) = try makeRunner(coordinator: coordinator, controller: controller, historyService: history, clock: FakeClock())

        let request = toolCallRequest(name: "search_history", arguments: .object(["query": .string(""), "limit": .int(2)]), token: settings.token)
        let (status, body) = await runner.handle(request, peer: identity)
        let response = try decode(body)
        #expect(status == 200)
        let json = try #require(text(from: response.result))
        let hits = try JSONDecoder().decode([DecodedHit].self, from: Data(json.utf8))
        #expect(hits.count == 2)
        #expect(hits.allSatisfy { $0.app == "Mail" && $0.words == 2 })
        #expect(hits.allSatisfy { $0.createdAt.hasSuffix("Z") })
    }

    @Test("search_history: limit 500 clamps to 100")
    func searchHistoryClampsLimit() async throws {
        let history = makeEnabledHistory()
        _ = await history.count()
        let store = try #require(history.store)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<105 {
            _ = try store.insert(DictationDraft(text: "note \(i)", rawText: "note \(i)", appName: nil, style: nil, language: "en",
                                                duration: 1, createdAt: base.addingTimeInterval(TimeInterval(i))))
        }

        let (coordinator, controller) = makeDictation(clock: FakeClock(), transcriber: FakeDictationTranscriber(result: .empty))
        let (runner, settings) = try makeRunner(coordinator: coordinator, controller: controller, historyService: history, clock: FakeClock())

        let request = toolCallRequest(name: "search_history", arguments: .object(["query": .string(""), "limit": .int(500)]), token: settings.token)
        let (status, body) = await runner.handle(request, peer: identity)
        let response = try decode(body)
        #expect(status == 200)
        let json = try #require(text(from: response.result))
        let hits = try JSONDecoder().decode([DecodedHit].self, from: Data(json.utf8))
        #expect(hits.count == 100)
    }

    @Test("search_history: an unreadable row (its encryption key no longer resolves) is skipped even though the store itself is ready")
    func searchHistorySkipsUnreadableRows() async throws {
        let dir = TemporaryDirectory()
        let dictationSettings = DictationSettings(store: InMemoryKeyValueStore())
        dictationSettings.retentionDays = 0
        let keyProvider = RotatingKeyProvider()
        let history = HistoryService(url: dir.file("voxflow.sqlite"), settings: dictationSettings, keyProvider: { keyProvider }, clock: FakeClock())
        await history.ready()
        let store = try #require(history.store)
        _ = try store.insert(DictationDraft(text: "secret note", rawText: "secret note", appName: nil, style: nil, language: "en",
                                            duration: 1, createdAt: Date(timeIntervalSince1970: 1)))

        keyProvider.rotate()   // the row above was encrypted under the *old* key
        history.reopen()
        await history.ready()
        #expect(history.status == .ready)   // the store itself opens fine; only that one row is unreadable

        let (coordinator, controller) = makeDictation(clock: FakeClock(), transcriber: FakeDictationTranscriber(result: .empty))
        let (runner, settings) = try makeRunner(coordinator: coordinator, controller: controller, historyService: history, clock: FakeClock())

        let request = toolCallRequest(name: "search_history", arguments: .object(["query": .string("")]), token: settings.token)
        let (status, body) = await runner.handle(request, peer: identity)
        let response = try decode(body)
        #expect(status == 200)
        let json = try #require(text(from: response.result))
        let hits = try JSONDecoder().decode([DecodedHit].self, from: Data(json.utf8))
        #expect(hits.isEmpty)   // the unreadable row never reaches an MCP client
    }

    // MARK: disabled tool re-check (test case 5)

    @Test("a disabled tool called by name → -32601 (the runner re-checks, not only tools/list)")
    func disabledToolReturnsMethodNotFound() async throws {
        let settings = makeSettings(dictate: false)
        let (coordinator, controller) = makeDictation(clock: FakeClock(), transcriber: FakeDictationTranscriber(result: .empty))
        let presenter = FakeApprovalPresenter(decision: .allow)
        let (runner, _) = try makeRunner(settings: settings, coordinator: coordinator, controller: controller, clock: FakeClock(),
                                         approvalPresenter: presenter)

        let request = toolCallRequest(name: "dictate", arguments: .object([:]), token: settings.token)
        let (status, body) = await runner.handle(request, peer: identity)
        let response = try decode(body)
        #expect(status == 404)
        #expect(response.error?.code == -32601)
        #expect(presenter.callCount == 0)   // never even reaches the approval gate
    }

    // MARK: approval (test case 6)

    @Test("an unapproved client asks the presenter exactly once and, on Always allow, writes one approved mcp_clients row")
    func unapprovedClientAlwaysAllowPersists() async throws {
        let clientStore = try MCPClientStore(database: VoxFlowDatabase.inMemory())
        let presenter = FakeApprovalPresenter(decision: .allow)
        let (coordinator, controller) = makeDictation(clock: FakeClock(), transcriber: FakeDictationTranscriber(result: .empty))
        let (runner, settings) = try makeRunner(coordinator: coordinator, controller: controller, clock: FakeClock(),
                                                clientStore: clientStore, approvalPresenter: presenter)

        // First call: unapproved, asks once, and allows this call through.
        let first = toolCallRequest(name: "search_history", arguments: .object(["query": .string("")]), token: settings.token, id: .number(1))
        let (status1, _) = await runner.handle(first, peer: identity)
        #expect(status1 == 200)
        #expect(presenter.callCount == 1)
        #expect(presenter.lastCall?.identity == identity)

        let rows = try clientStore.all()
        #expect(rows.count == 1)
        #expect(rows.first?.name == identity.name && rows.first?.path == identity.path && rows.first?.approved == true)

        // Second call: already approved (persisted) — the presenter is not asked again.
        let second = toolCallRequest(name: "search_history", arguments: .object(["query": .string("")]), token: settings.token, id: .number(2))
        let (status2, _) = await runner.handle(second, peer: identity)
        #expect(status2 == 200)
        #expect(presenter.callCount == 1)
    }

    @Test("an unapproved client on Deny answers -32001 and is not asked again in the same session")
    func unapprovedClientDenyDoesNotReask() async throws {
        let presenter = FakeApprovalPresenter(decision: .deny)
        let (coordinator, controller) = makeDictation(clock: FakeClock(), transcriber: FakeDictationTranscriber(result: .empty))
        let (runner, settings) = try makeRunner(coordinator: coordinator, controller: controller, clock: FakeClock(), approvalPresenter: presenter)

        let first = toolCallRequest(name: "search_history", arguments: .object(["query": .string("")]), token: settings.token, id: .number(1))
        let (status1, body1) = await runner.handle(first, peer: identity)
        let response1 = try decode(body1)
        #expect(status1 == 401)
        #expect(response1.error?.code == -32001)
        #expect(presenter.callCount == 1)

        let second = toolCallRequest(name: "search_history", arguments: .object(["query": .string("")]), token: settings.token, id: .number(2))
        let (status2, body2) = await runner.handle(second, peer: identity)
        let response2 = try decode(body2)
        #expect(status2 == 401)
        #expect(response2.error?.code == -32001)
        #expect(presenter.callCount == 1)   // not asked again this session
    }

    @Test("an empty resolved peer name is shown to the approval presenter as \"Unknown app\"")
    func unresolvedPeerDisplaysAsUnknownApp() async throws {
        let presenter = FakeApprovalPresenter(decision: .allow)
        let (coordinator, controller) = makeDictation(clock: FakeClock(), transcriber: FakeDictationTranscriber(result: .empty))
        let (runner, settings) = try makeRunner(coordinator: coordinator, controller: controller, clock: FakeClock(), approvalPresenter: presenter)

        let unresolved = MCPClientIdentity(name: "", path: "", pid: nil)
        let request = toolCallRequest(name: "search_history", arguments: .object(["query": .string("")]), token: settings.token)
        _ = await runner.handle(request, peer: unresolved)
        #expect(presenter.lastCall?.identity.name == "Unknown app")
    }
}
