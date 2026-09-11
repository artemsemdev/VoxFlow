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

/// Records every `present(identity:tools:canPersist:)` call and answers a scripted decision —
/// `MCPToolRunner`'s approval seam (`MCPApprovalPresenting`) is defined in `MCPToolRunner.swift`;
/// Task 4 supplies the real SwiftUI panel, this is the test double. `gate`, when given, makes
/// `present` suspend on it before answering — lets a test hold a first "ask" open long enough to
/// start a second concurrent call and prove it's deduplicated rather than presenting twice.
private final class FakeApprovalPresenter: MCPApprovalPresenting, Sendable {
    private struct State {
        var decision: MCPClientDecision
        var calls: [(identity: MCPClientIdentity, tools: [String], canPersist: Bool)] = []
    }
    private let state: Mutex<State>
    private let gate: Gate?

    init(decision: MCPClientDecision, gate: Gate? = nil) {
        state = Mutex(State(decision: decision))
        self.gate = gate
    }

    var callCount: Int { state.withLock { $0.calls.count } }
    var lastCall: (identity: MCPClientIdentity, tools: [String], canPersist: Bool)? { state.withLock { $0.calls.last } }

    func present(identity: MCPClientIdentity, tools: [String], canPersist: Bool) async -> MCPClientDecision {
        state.withLock { $0.calls.append((identity, tools, canPersist)) }
        if let gate { await gate.wait() }
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

    func makeDictation(clock: FakeClock, transcriber: FakeDictationTranscriber, mic: FakeMicrophone = FakeMicrophone(),
                       preflight: Preflight = Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .loaded),
                       loadModel: @escaping @Sendable () async throws -> Void = {})
        -> (DictationCoordinator, DictationController) {
        let controller = DictationController(config: FlowBarConfig(), microphone: mic, transcriber: transcriber, inserter: FakeTextInserter(), clock: clock,
                                             preflight: { preflight },
                                             loadModel: loadModel, options: { TranscriptionOptions() }, onSave: { _, _ in }, copyToClipboard: { _ in })
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
        return HistoryService(directory: dir, settings: settings, keyProvider: { FakeMCPHistoryKeyProvider() }, clock: FakeClock())
    }

    /// Same trick `HistoryServiceTests.databaseNilWhenFileUnopenable` uses: a file sits where a
    /// parent directory needs to be, so `VoxFlowDatabase.init(url:)`'s `createDirectory` fails and
    /// the open never succeeds — `status` ends up `.disabled(reason:)`. Forces the open (`ready()`)
    /// The injected fixture opener retains this directory while the service is alive.
    func makeDisabledHistory() async throws -> HistoryService {
        let dir = TemporaryDirectory()
        let blocker = dir.file("blocker")
        try Data().write(to: blocker)
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        let service = HistoryService(directory: dir, relativePath: "blocker/nested/voxflow.sqlite", settings: settings, keyProvider: { FakeMCPHistoryKeyProvider() }, clock: FakeClock())
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
        let (status, body) = await runner.handle(request, peer: MCPPeer(identity))
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
        let (status, body) = await runner.handle(request, peer: MCPPeer(identity))
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
        let (status, body) = await runner.handle(request, peer: MCPPeer(identity))
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
        let (status, body) = await runner.handle(request, peer: MCPPeer(identity))
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
        let (status, body) = await runner.handle(request, peer: MCPPeer(identity))
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
        let (status, body) = await runner.handle(request, peer: MCPPeer(identity))
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
        let task = Task { await runner.handle(request, peer: MCPPeer(identity)) }
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
        let task = Task { await runner.handle(request, peer: MCPPeer(identity)) }
        await clock.waitForSleepers(3)               // cap + silence (FlowBarMachine) + this dictate call's own timeout
        await clock.advance(by: 920)                  // default maxDuration(900) + processingTimeout(20)
        let (status, body) = await task.value
        let response = try decode(body)
        #expect(status == 200)
        #expect(response.error?.code == -32003)
        #expect(response.error?.message == "Dictation timed out.")
    }

    // MARK: dictate — concurrency (review C1)

    @Test("two concurrent dictate calls: dictateInFlight is authoritative — exactly one capture starts, the other is refused with -32002, and the single result goes only to the first")
    func concurrentDictateCallsOnlyOneWins() async throws {
        let clock = FakeClock()
        let mic = FakeMicrophone()
        let preflightGate = Gate()
        let transcriber = FakeDictationTranscriber(result: DictationResult(text: "only mine", rawText: "only mine",
                                                                            segments: [], language: nil, duration: 1, lowConfidence: false))
        // Built directly (not via `makeDictation`) with a *gated* preflight — resolving preflight
        // immediately would let the FSM (and so `coordinator.isHUDActive`) catch up before task2
        // gets a chance to run; gating it keeps `isHUDActive` observably `false` for as long as the
        // test needs, proving the refusal below comes from `dictateInFlight`, not the mirror.
        let controller = DictationController(config: FlowBarConfig(), microphone: mic, transcriber: transcriber, inserter: FakeTextInserter(), clock: clock,
                                             preflight: { await preflightGate.wait(); return Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .loaded) },
                                             loadModel: {}, options: { TranscriptionOptions() }, onSave: { _, _ in }, copyToClipboard: { _ in })
        let dictationSettings = DictationSettings(store: InMemoryKeyValueStore())
        let permissions = FakePermissions(microphone: .granted, requestResult: .granted, accessibility: true)
        let coordinator = DictationCoordinator(controller: controller, settings: dictationSettings, permissions: permissions,
                                               navigation: Navigation(), clock: clock)
        coordinator.start()
        let (runner, settings) = try makeRunner(coordinator: coordinator, controller: controller, clock: clock)

        let req1 = toolCallRequest(name: "dictate", arguments: .object([:]), token: settings.token, id: .number(1))
        let req2 = toolCallRequest(name: "dictate", arguments: .object([:]), token: settings.token, id: .number(2))

        let task1 = Task { await runner.handle(req1, peer: MCPPeer(identity)) }
        // `dictate()`'s guard-and-set prefix (including `dictateInFlight = true` and subscribing to
        // `results()`/`states()`) runs within a handful of actor hops, all *before* the gated
        // `preflight()` deep inside the coordinator's command queue is ever reached — give it
        // generous room to get there while nothing FSM-visible can happen yet.
        for _ in 0..<20 { await Task.yield() }
        #expect(!coordinator.isHUDActive)   // the (stale) coordinator mirror hasn't caught up — by design

        let task2 = Task { await runner.handle(req2, peer: MCPPeer(identity)) }
        let (status2, body2) = await task2.value
        let response2 = try decode(body2)
        #expect(status2 == 200)
        #expect(response2.error?.code == -32002)
        #expect(response2.error?.message == "A dictation is already running.")

        await preflightGate.open()
        await mic.waitUntilCapturing()
        mic.emit(rms: 0.3, seconds: 1)
        await transcriber.waitUntilReceived(1)
        await clock.waitForSleepers(3)
        await clock.advance(by: 3)
        let (status1, body1) = await task1.value
        let response1 = try decode(body1)
        #expect(status1 == 200)
        #expect(text(from: response1.result) == "only mine")
    }

    // MARK: dictate — fast failure (review item 6, -32005)

    @Test("MCPToolError.dictationFailureReason renders the fixed copy for every terminal failure state, verbatim")
    func dictationFailureReasonCopy() {
        #expect(MCPToolError.dictationFailureReason(for: .discarded) == "Dictation was discarded.")
        #expect(MCPToolError.dictationFailureReason(for: .didntCatch(rawAvailable: false)) == "VoxFlow didn't catch that.")
        #expect(MCPToolError.dictationFailureReason(for: .didntCatch(rawAvailable: true)) == "VoxFlow didn't catch that.")
        #expect(MCPToolError.dictationFailureReason(for: .micUnavailable(.denied)) == "Microphone access needed.")
        #expect(MCPToolError.dictationFailureReason(for: .micUnavailable(.noDevice)) == "No microphone.")
        #expect(MCPToolError.dictationFailureReason(for: .micUnavailable(.granted)) == "Microphone unavailable.")
        #expect(MCPToolError.dictationFailureReason(for: .micUnavailable(.inUse(by: "Zoom"))) == "Microphone in use by Zoom.")
        #expect(MCPToolError.dictationFailureReason(for: .micUnavailable(.inUse(by: nil))) == "Microphone in use by another app.")
        #expect(MCPToolError.dictationFailureReason(for: .excluded(app: "1Password")) == "Dictation is off in 1Password.")
        #expect(MCPToolError.dictationFailureReason(for: .modelNotInstalled(sizeBytes: 100)) == "The speech model isn't installed.")
        #expect(MCPToolError.dictationFailureReason(for: .error("boom")) == "boom")
        // States that still might produce (or already produced) a result are not failures.
        #expect(MCPToolError.dictationFailureReason(for: .idle) == nil)
        #expect(MCPToolError.dictationFailureReason(for: .inserted(appName: "Mail", words: 3, limitReached: false)) == nil)
        #expect(MCPToolError.dictationFailureReason(for: .copied(.noTextField)) == nil)
    }

    @Test("dictate fails fast with -32005 when the capture is discarded (Escape)")
    func dictateFailsFastOnDiscarded() async throws {
        let clock = FakeClock()
        let mic = FakeMicrophone()
        let (coordinator, controller) = makeDictation(clock: clock, transcriber: FakeDictationTranscriber(result: .empty, hold: Gate()), mic: mic)
        let (runner, settings) = try makeRunner(coordinator: coordinator, controller: controller, clock: clock)

        let request = toolCallRequest(name: "dictate", arguments: .object([:]), token: settings.token)
        let task = Task { await runner.handle(request, peer: MCPPeer(identity)) }
        await mic.waitUntilCapturing()
        coordinator.escape()
        let (status, body) = await task.value
        let response = try decode(body)
        #expect(status == 200)
        #expect(response.error?.code == -32005)
        #expect(response.error?.message == "Dictation was discarded.")
    }

    @Test("dictate fails fast with -32005 when the capture didn't catch anything (empty transcript)")
    func dictateFailsFastOnDidntCatch() async throws {
        let clock = FakeClock()
        let mic = FakeMicrophone()
        let (coordinator, controller) = makeDictation(clock: clock, transcriber: FakeDictationTranscriber(result: .empty), mic: mic)
        let (runner, settings) = try makeRunner(coordinator: coordinator, controller: controller, clock: clock)

        let request = toolCallRequest(name: "dictate", arguments: .object([:]), token: settings.token)
        let task = Task { await runner.handle(request, peer: MCPPeer(identity)) }
        await mic.waitUntilCapturing()
        await clock.waitForSleepers(3)   // cap + silence + this dictate call's own timeout
        await clock.advance(by: 3)        // FlowBarConfig.silenceStop default — well short of the full budget
        let (status, body) = await task.value
        let response = try decode(body)
        #expect(status == 200)
        #expect(response.error?.code == -32005)
        #expect(response.error?.message == "VoxFlow didn't catch that.")
    }

    @Test("dictate fails fast with -32005 when the speech model fails to load")
    func dictateFailsFastOnModelLoadError() async throws {
        struct LoadFailed: Error {}
        let clock = FakeClock()
        let (coordinator, controller) = makeDictation(clock: clock, transcriber: FakeDictationTranscriber(result: .empty),
                                                       preflight: Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .installedNotLoaded),
                                                       loadModel: { throw LoadFailed() })
        let (runner, settings) = try makeRunner(coordinator: coordinator, controller: controller, clock: clock)

        let request = toolCallRequest(name: "dictate", arguments: .object([:]), token: settings.token)
        let (status, body) = await runner.handle(request, peer: MCPPeer(identity))
        let response = try decode(body)
        #expect(status == 200)
        #expect(response.error?.code == -32005)
        #expect(response.error?.message == "Couldn't load the speech model")
    }

    @Test("dictate fails fast with -32005 when the microphone is unavailable")
    func dictateFailsFastOnMicUnavailable() async throws {
        let clock = FakeClock()
        let (coordinator, controller) = makeDictation(clock: clock, transcriber: FakeDictationTranscriber(result: .empty),
                                                       preflight: Preflight(excludedApp: nil, secureInput: false, microphone: .denied, model: .loaded))
        let (runner, settings) = try makeRunner(coordinator: coordinator, controller: controller, clock: clock)

        let request = toolCallRequest(name: "dictate", arguments: .object([:]), token: settings.token)
        let (status, body) = await runner.handle(request, peer: MCPPeer(identity))
        let response = try decode(body)
        #expect(status == 200)
        #expect(response.error?.code == -32005)
        #expect(response.error?.message == "Microphone access needed.")
    }

    @Test("dictate fails fast with -32005 when dictation is excluded in the (notional) focused app")
    func dictateFailsFastOnExcludedApp() async throws {
        let clock = FakeClock()
        let (coordinator, controller) = makeDictation(clock: clock, transcriber: FakeDictationTranscriber(result: .empty),
                                                       preflight: Preflight(excludedApp: "1Password", secureInput: false, microphone: .granted, model: .loaded))
        let (runner, settings) = try makeRunner(coordinator: coordinator, controller: controller, clock: clock)

        let request = toolCallRequest(name: "dictate", arguments: .object([:]), token: settings.token)
        let (status, body) = await runner.handle(request, peer: MCPPeer(identity))
        let response = try decode(body)
        #expect(status == 200)
        #expect(response.error?.code == -32005)
        #expect(response.error?.message == "Dictation is off in 1Password.")
    }

    @Test("dictate fails fast with -32005 when the speech model isn't installed")
    func dictateFailsFastOnModelNotInstalled() async throws {
        let clock = FakeClock()
        let (coordinator, controller) = makeDictation(clock: clock, transcriber: FakeDictationTranscriber(result: .empty),
                                                       preflight: Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .notInstalled(sizeBytes: 100)))
        let (runner, settings) = try makeRunner(coordinator: coordinator, controller: controller, clock: clock)

        let request = toolCallRequest(name: "dictate", arguments: .object([:]), token: settings.token)
        let (status, body) = await runner.handle(request, peer: MCPPeer(identity))
        let response = try decode(body)
        #expect(status == 200)
        #expect(response.error?.code == -32005)
        #expect(response.error?.message == "The speech model isn't installed.")
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
        let (status, body) = await runner.handle(request, peer: MCPPeer(identity))
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
        let (status, body) = await runner.handle(request, peer: MCPPeer(identity))
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
        let (status, body) = await runner.handle(request, peer: MCPPeer(identity))
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
        let history = HistoryService(directory: dir, settings: dictationSettings, keyProvider: { keyProvider }, clock: FakeClock())
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
        let (status, body) = await runner.handle(request, peer: MCPPeer(identity))
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
        let (status, body) = await runner.handle(request, peer: MCPPeer(identity))
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
        let (status1, _) = await runner.handle(first, peer: MCPPeer(identity))
        #expect(status1 == 200)
        #expect(presenter.callCount == 1)
        #expect(presenter.lastCall?.identity == identity)

        let rows = try clientStore.all()
        #expect(rows.count == 1)
        #expect(rows.first?.name == identity.name && rows.first?.path == identity.path && rows.first?.approved == true)

        // Second call: already approved (persisted) — the presenter is not asked again.
        let second = toolCallRequest(name: "search_history", arguments: .object(["query": .string("")]), token: settings.token, id: .number(2))
        let (status2, _) = await runner.handle(second, peer: MCPPeer(identity))
        #expect(status2 == 200)
        #expect(presenter.callCount == 1)
    }

    @Test("an unapproved client on Deny answers -32001 and is not asked again in the same session")
    func unapprovedClientDenyDoesNotReask() async throws {
        let presenter = FakeApprovalPresenter(decision: .deny)
        let (coordinator, controller) = makeDictation(clock: FakeClock(), transcriber: FakeDictationTranscriber(result: .empty))
        let (runner, settings) = try makeRunner(coordinator: coordinator, controller: controller, clock: FakeClock(), approvalPresenter: presenter)

        let first = toolCallRequest(name: "search_history", arguments: .object(["query": .string("")]), token: settings.token, id: .number(1))
        let (status1, body1) = await runner.handle(first, peer: MCPPeer(identity))
        let response1 = try decode(body1)
        #expect(status1 == 401)
        #expect(response1.error?.code == -32001)
        #expect(presenter.callCount == 1)

        let second = toolCallRequest(name: "search_history", arguments: .object(["query": .string("")]), token: settings.token, id: .number(2))
        let (status2, body2) = await runner.handle(second, peer: MCPPeer(identity))
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
        _ = await runner.handle(request, peer: MCPPeer(unresolved))
        #expect(presenter.lastCall?.identity.name == "Unknown app")
    }

    // MARK: approval — concurrency, revoke, Allow once, unresolved identity (review items 2/3/4/8)

    @Test("two concurrent first calls from the same unapproved client ask the presenter once and both get the same decision")
    func concurrentFirstCallsAskPresenterOnce() async throws {
        let gate = Gate()
        let presenter = FakeApprovalPresenter(decision: .allow, gate: gate)
        let (coordinator, controller) = makeDictation(clock: FakeClock(), transcriber: FakeDictationTranscriber(result: .empty))
        let (runner, settings) = try makeRunner(coordinator: coordinator, controller: controller, clock: FakeClock(), approvalPresenter: presenter)

        let req1 = toolCallRequest(name: "search_history", arguments: .object(["query": .string("")]), token: settings.token, id: .number(1))
        let req2 = toolCallRequest(name: "search_history", arguments: .object(["query": .string("")]), token: settings.token, id: .number(2))
        let task1 = Task { await runner.handle(req1, peer: MCPPeer(identity)) }
        // Wait until task1 has actually reached (and registered) the presenter call before starting
        // task2 — proves task2 finds the in-flight decision already recorded, not a race on who gets
        // there first.
        while presenter.callCount == 0 { await Task.yield() }
        let task2 = Task { await runner.handle(req2, peer: MCPPeer(identity)) }

        await gate.open()
        let (status1, _) = await task1.value
        let (status2, _) = await task2.value
        #expect(status1 == 200)
        #expect(status2 == 200)
        #expect(presenter.callCount == 1)
    }

    @Test("a revoke between two calls makes the second call ask the presenter again")
    func revokeBetweenCallsAsksAgain() async throws {
        let clientStore = try MCPClientStore(database: VoxFlowDatabase.inMemory())
        let presenter = FakeApprovalPresenter(decision: .allow)
        let (coordinator, controller) = makeDictation(clock: FakeClock(), transcriber: FakeDictationTranscriber(result: .empty))
        let (runner, settings) = try makeRunner(coordinator: coordinator, controller: controller, clock: FakeClock(),
                                                clientStore: clientStore, approvalPresenter: presenter)

        let first = toolCallRequest(name: "search_history", arguments: .object(["query": .string("")]), token: settings.token, id: .number(1))
        let (status1, _) = await runner.handle(first, peer: MCPPeer(identity))
        #expect(status1 == 200)
        #expect(presenter.callCount == 1)
        let rows = try clientStore.all()
        #expect(rows.count == 1 && rows[0].approved == true)

        try clientStore.revoke(id: rows[0].id)

        let second = toolCallRequest(name: "search_history", arguments: .object(["query": .string("")]), token: settings.token, id: .number(2))
        let (status2, _) = await runner.handle(second, peer: MCPPeer(identity))
        #expect(status2 == 200)             // the fake presenter answers `.allow` again
        #expect(presenter.callCount == 2)   // asked again — the revoke took effect on the very next call
    }

    @Test("Allow once is scoped to the app session and never persisted, but the presenter is not asked again this session")
    func allowOnceIsSessionScopedNotPersisted() async throws {
        let clientStore = try MCPClientStore(database: VoxFlowDatabase.inMemory())
        let presenter = FakeApprovalPresenter(decision: .allowOnce)
        let (coordinator, controller) = makeDictation(clock: FakeClock(), transcriber: FakeDictationTranscriber(result: .empty))
        let (runner, settings) = try makeRunner(coordinator: coordinator, controller: controller, clock: FakeClock(),
                                                clientStore: clientStore, approvalPresenter: presenter)

        let first = toolCallRequest(name: "search_history", arguments: .object(["query": .string("")]), token: settings.token, id: .number(1))
        let (status1, _) = await runner.handle(first, peer: MCPPeer(identity))
        #expect(status1 == 200)
        #expect(try clientStore.all().isEmpty)   // never persisted

        let second = toolCallRequest(name: "search_history", arguments: .object(["query": .string("")]), token: settings.token, id: .number(2))
        let (status2, _) = await runner.handle(second, peer: MCPPeer(identity))
        #expect(status2 == 200)
        #expect(presenter.callCount == 1)        // not asked again this session
        #expect(try clientStore.all().isEmpty)   // still never persisted
    }

    @Test("an unidentified client's Always allow does not persist — canPersist is false and the answer degrades to a session-scoped grant")
    func unresolvedIdentityAllowDoesNotPersist() async throws {
        let clientStore = try MCPClientStore(database: VoxFlowDatabase.inMemory())
        // The presenter shouldn't offer "Always allow" when `canPersist` is false (Task 4's job) —
        // this scripts `.allow` anyway to prove the runner itself refuses to persist it regardless.
        let presenter = FakeApprovalPresenter(decision: .allow)
        let (coordinator, controller) = makeDictation(clock: FakeClock(), transcriber: FakeDictationTranscriber(result: .empty))
        let (runner, settings) = try makeRunner(coordinator: coordinator, controller: controller, clock: FakeClock(),
                                                clientStore: clientStore, approvalPresenter: presenter)

        let unresolved = MCPClientIdentity(name: "", path: "", pid: nil)
        let first = toolCallRequest(name: "search_history", arguments: .object(["query": .string("")]), token: settings.token, id: .number(1))
        let (status1, _) = await runner.handle(first, peer: MCPPeer(unresolved))
        #expect(status1 == 200)
        #expect(presenter.lastCall?.canPersist == false)
        #expect(try clientStore.all().isEmpty)   // never persisted despite `.allow`

        // The `.allow` degraded to a session-scoped grant, so the same (still-unresolved) identity
        // isn't asked again this session.
        let second = toolCallRequest(name: "search_history", arguments: .object(["query": .string("")]), token: settings.token, id: .number(2))
        let (status2, _) = await runner.handle(second, peer: MCPPeer(unresolved))
        #expect(status2 == 200)
        #expect(presenter.callCount == 1)
    }

    @Test("clearSessionDecisions forgets an Allow once grant, so the next call asks again (final review F3)")
    func clearSessionDecisionsForgetsAllowOnce() async throws {
        let clientStore = try MCPClientStore(database: VoxFlowDatabase.inMemory())
        let presenter = FakeApprovalPresenter(decision: .allowOnce)
        let (coordinator, controller) = makeDictation(clock: FakeClock(), transcriber: FakeDictationTranscriber(result: .empty))
        let (runner, settings) = try makeRunner(coordinator: coordinator, controller: controller, clock: FakeClock(),
                                                clientStore: clientStore, approvalPresenter: presenter)

        let first = toolCallRequest(name: "search_history", arguments: .object(["query": .string("")]), token: settings.token, id: .number(1))
        _ = await runner.handle(first, peer: MCPPeer(identity))
        let second = toolCallRequest(name: "search_history", arguments: .object(["query": .string("")]), token: settings.token, id: .number(2))
        _ = await runner.handle(second, peer: MCPPeer(identity))
        #expect(presenter.callCount == 1)   // the session grant held

        runner.clearSessionDecisions()

        let third = toolCallRequest(name: "search_history", arguments: .object(["query": .string("")]), token: settings.token, id: .number(3))
        _ = await runner.handle(third, peer: MCPPeer(identity))
        #expect(presenter.callCount == 2)   // asked again — the grant is gone
        #expect(try clientStore.all().isEmpty)  // and it was never persisted
    }
}
