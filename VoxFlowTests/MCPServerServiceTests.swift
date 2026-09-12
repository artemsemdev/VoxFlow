import Foundation
import Testing
import VoxFlowMCP
import VoxFlowStorage
import VoxFlowTestSupport
@testable import VoxFlow

/// Deliberately ignores cancellation: tests release obsolete completions after a newer operation.
@MainActor
private final class ServiceGate {
    private let entries = AsyncStream<Void>.makeStream()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    func wait() async {
        entries.continuation.yield()
        if !opened { await withCheckedContinuation { waiters.append($0) } }
    }
    func entered() async { for await _ in entries.stream { return } }
    func release() { opened = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
    func finish() { release(); entries.continuation.finish() }
}

@MainActor
private final class ServiceTransport: MCPServerTransport {
    var port: UInt16?
    var starts = 0
    var startGate: ServiceGate?
    var portGate: ServiceGate?
    var stopGate: ServiceGate?
    let assignedPort: UInt16
    init(port: UInt16) { assignedPort = port }
    var boundPort: UInt16? {
        get async { let snapshot = port; await portGate?.wait(); return snapshot }
    }
    func start() async throws { starts += 1; await startGate?.wait(); port = assignedPort }
    func stop() async { await stopGate?.wait(); port = nil }
}

@Suite("MCP service lifecycle without external resources", .timeLimit(.minutes(1)))
@MainActor
struct MCPServerServiceTests {
    @MainActor private final class Harness {
        let databaseGate = ServiceGate()
        let settings: MCPSettings
        let service: MCPServerService
        let vm: MCPViewModel
        let approvals = DenyPresenter()
        final class Probe {
            var databaseLoads = 0
            var runners: [MCPToolRunner] = []
            var transports: [ServiceTransport] = []
            var portGate: ServiceGate?
            var startGate: ServiceGate?
        }
        let probe = Probe()
        init() throws {
            let helpers = MCPToolRunnerTests()
            let clock = FakeClock()
            let (coordinator, controller) = helpers.makeDictation(clock: clock, transcriber: FakeDictationTranscriber(result: .empty))
            settings = helpers.makeSettings()
            let database = try VoxFlowDatabase.inMemory()
            let probe = probe, gate = databaseGate
            service = MCPServerService(settings: settings, coordinator: coordinator, controller: controller,
                historyService: helpers.makeEnabledHistory(), fileTranscribing: FakeFileTranscriber(),
                pathPolicy: PathPolicy(homeDirectory: URL(fileURLWithPath: "/tmp"), allowedExtensions: ["wav"]),
                clock: clock, approvalPresenter: approvals, serverVersion: "test", loadDatabase: {
                    probe.databaseLoads += 1
                    await gate.wait()
                    return database
                }, makeTransport: { runner in
                    let transport = ServiceTransport(port: 7331 + UInt16(probe.transports.count))
                    transport.portGate = probe.portGate
                    transport.startGate = probe.startGate
                    probe.runners.append(runner)
                    probe.transports.append(transport)
                    return transport
                })
            vm = MCPViewModel(settings: settings, pasteboard: FakePasteboard(), server: service,
                              clientStoreProvider: service, approvalObserver: FakeApprovalObserver())
        }
    }
    @MainActor private final class DenyPresenter: MCPApprovalPresenting {
        var calls = 0
        func present(identity: MCPClientIdentity, tools: [String], canPersist: Bool) async -> MCPClientDecision {
            calls += 1
            return .deny
        }
    }

    @Test("stdio handshake and notifications need no transport, token, database or approval")
    func stdioHandshake() async throws {
        let h = try Harness()
        defer { h.databaseGate.finish() }
        let data = try #require(await h.service.handleStdio(JSONRPCRequest(id: .number(1), method: "initialize")))
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: data)
        #expect(response.id == .number(1))
        #expect(response.result?["serverInfo"]?["version"]?.stringValue == "test")
        #expect(await h.service.handleStdio(JSONRPCRequest(method: "notifications/initialized")) == nil)
        #expect(h.probe.databaseLoads == 0 && h.probe.transports.isEmpty && h.approvals.calls == 0)
        let invalidVersion = try #require(await h.service.handleStdio(JSONRPCRequest(id: .number(4), method: "tools/list",
            params: .object(["_meta": .object([MCPMetaKey.protocolVersion: .string("unsupported")])]))))
        #expect(try JSONDecoder().decode(JSONRPCResponse.self, from: invalidVersion).error != nil)
    }

    @Test("stdio retains disabled-tool and file-path policies without creating an HTTP grant")
    func stdioToolPolicies() async throws {
        let h = try Harness()
        defer { h.databaseGate.finish() }
        h.settings.toolSearchHistory = false
        let disabled = try #require(await h.service.handleStdio(JSONRPCRequest(id: .number(2), method: "tools/call",
            params: .object(["name": .string("search_history")]))))
        #expect(try JSONDecoder().decode(JSONRPCResponse.self, from: disabled).error != nil)
        #expect(h.probe.databaseLoads == 0)
        h.databaseGate.release()
        let invalid = try #require(await h.service.handleStdio(JSONRPCRequest(id: .number(3), method: "tools/call",
            params: .object(["name": .string("transcribe_file"),
                "arguments": .object(["path": .string("/etc/passwd")])]))))
        #expect(try JSONDecoder().decode(JSONRPCResponse.self, from: invalid).error != nil)
        #expect(h.probe.transports.isEmpty && h.approvals.calls == 0)
    }

    @Test("stop during lazy resolution prevents an old start from binding or enabling settings",
          arguments: [false, true])
    func stoppedResolution(restart: Bool) async throws {
        let h = try Harness()
        defer { h.databaseGate.finish() }
        let old = Task { await h.vm.setEnabled(true) }
        await h.databaseGate.entered()
        await h.vm.setEnabled(false)
        let fresh = restart ? Task { await h.vm.setEnabled(true) } : nil
        h.databaseGate.release()
        await old.value
        await fresh?.value
        #expect(h.probe.transports.count == (restart ? 1 : 0))
        #expect(h.service.boundPort == (restart ? 7331 : nil))
        #expect(h.vm.enabled == restart)
        #expect(h.settings.enabled == restart)
    }

    @Test("concurrent first reads and starts share their client store, runner and transport")
    func sharedInitialization() async throws {
        let h = try Harness()
        defer { h.databaseGate.finish() }
        let store = Task { await h.service.resolvedClientStore() }
        await h.databaseGate.entered()
        let entered = AsyncStream<Void>.makeStream()
        defer { entered.continuation.finish() }
        // Each main-actor caller runs into the held resolution before yielding this actor.
        let first = Task { entered.continuation.yield(); try await h.service.start() }
        let second = Task { entered.continuation.yield(); try await h.service.start() }
        var entries = entered.stream.makeAsyncIterator()
        await entries.next()
        await entries.next()
        h.databaseGate.release()
        try await first.value
        try await second.value
        let original = await store.value
        #expect(await h.service.resolvedClientStore() === original)
        #expect(h.probe.databaseLoads == 1)
        #expect(h.probe.transports.count == 1)
        #expect(h.probe.transports.first?.starts == 1)
        #expect(h.probe.runners.first?.boundPort == 7331)
        let runner = try #require(h.probe.runners.first)
        let request = MCPToolRunnerTests().toolCallRequest(name: "dictate", arguments: .object([:]), token: h.settings.token)
        let peer = MCPPeer(MCPClientIdentity(name: "Test", path: "/tmp/test-client", pid: nil))
        _ = await runner.handle(request, peer: peer)
        _ = await runner.handle(request, peer: peer)
        #expect(h.approvals.calls == 1)
        await h.service.clearSessionDecisions()
        _ = await runner.handle(request, peer: peer)
        #expect(h.approvals.calls == 2)
        await h.service.stop()
        #expect(h.probe.runners.first?.boundPort == 0)
    }

    @Test("an obsolete bound-port read cannot overwrite a fresh start")
    func stalePortRead() async throws {
        let h = try Harness()
        defer { h.databaseGate.finish() }
        h.databaseGate.release()
        let gate = ServiceGate()
        defer { gate.finish() }
        h.probe.portGate = gate
        let old = Task { try await h.service.start() }
        await gate.entered()
        await h.service.stop()
        h.probe.portGate = nil
        h.probe.transports.first?.portGate = nil
        try await h.service.start()
        let freshPort = h.service.boundPort
        gate.release()
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(h.service.boundPort == freshPort)
    }

    @Test("a slow older stop cannot clear a restarted server or its settings")
    func staleStop() async throws {
        let h = try Harness()
        defer { h.databaseGate.finish() }
        h.databaseGate.release()
        await h.vm.setEnabled(true)
        let transport = try #require(h.probe.transports.first)
        let gate = ServiceGate()
        defer { gate.finish() }
        transport.stopGate = gate
        let old = Task { await h.vm.setEnabled(false) }
        await gate.entered()
        await h.vm.setEnabled(true)
        let freshPort = h.service.boundPort
        gate.release()
        await old.value
        #expect(h.vm.enabled)
        #expect(h.settings.enabled)
        #expect(h.service.boundPort == freshPort)
        #expect(h.probe.runners.last?.boundPort == freshPort)
    }

    @Test("late readiness is cleaned up on its own transport without stopping the replacement")
    func staleTransportCompletion() async throws {
        let h = try Harness()
        defer { h.databaseGate.finish() }
        h.databaseGate.release()
        let gate = ServiceGate()
        defer { gate.finish() }
        h.probe.startGate = gate
        let old = Task { try await h.service.start() }
        await gate.entered()
        let transport = try #require(h.probe.transports.first)
        await h.service.stop()
        h.probe.startGate = nil
        try await h.service.start()
        gate.release()
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(transport.port == nil)
        #expect(h.probe.transports.last?.port == 7332)
        #expect(h.service.boundPort == 7332)
    }
}
