import Testing
import VoxFlowCore
import VoxFlowMCP
import VoxFlowTestSupport
@testable import VoxFlow

/// ST-06a copy — pure, no window needed. Characters matched against the rendered canvas
/// (`canvas.pdf` page 5): curly quotes around the app name, `·` before the loopback address.
@Suite("MCPApprovalCopy")
struct MCPApprovalCopyTests {
    @Test("title/body/process line match the ST-06a canvas verbatim")
    func copyMatchesCanvas() {
        #expect(MCPApprovalCopy.title(name: "Cursor") == "\u{201C}Cursor\u{201D} wants to use VoxFlow")
        #expect(MCPApprovalCopy.body(tools: ["transcribe_file", "dictate"]) ==
               "A local app connected to the MCP server with a valid token. It can use: transcribe_file, dictate.")
        #expect(MCPApprovalCopy.processLine(name: "Cursor", pid: 4812) == "Process: Cursor (pid 4812) · 127.0.0.1")
    }

    @Test("a single enabled tool still reads naturally")
    func singleTool() {
        #expect(MCPApprovalCopy.body(tools: ["dictate"]) ==
               "A local app connected to the MCP server with a valid token. It can use: dictate.")
    }

    @Test("a nil pid (peer resolution failed) doesn't crash — falls back to \"unknown\"")
    func nilPID() {
        #expect(MCPApprovalCopy.processLine(name: "Unknown app", pid: nil) == "Process: Unknown app (pid unknown) · 127.0.0.1")
    }
}

@Suite("MCPApprovalViewModel", .timeLimit(.minutes(1)))
@MainActor
struct MCPApprovalViewModelTests {
    let identity = MCPClientIdentity(name: "Cursor", path: "/Applications/Cursor.app/Contents/MacOS/Cursor", pid: 4812)

    /// Fakes the real `MCPApprovalPanel` — no `NSPanel` is ever created in these tests.
    final class FakePanel: MCPApprovalPanelPresenting {
        private(set) var shown = false
        private(set) var hidden = false
        func show() { shown = true }
        func hide() { hidden = true }
    }

    /// Captures the arguments/closures `MCPApprovalViewModel.present` hands to `makePanel` —
    /// synchronously set by the time `present`'s first suspension point is reached, since
    /// `withCheckedContinuation`'s body (which calls `makePanel`) runs before any `await`.
    final class Callbacks {
        var canPersist: Bool?
        var onAlwaysAllow: (() -> Void)?
        var onAllowOnce: (() -> Void)?
        var onDeny: (() -> Void)?
    }

    func harness(clock: any MonotonicClock) -> (vm: MCPApprovalViewModel, panel: FakePanel, callbacks: Callbacks) {
        let panel = FakePanel()
        let callbacks = Callbacks()
        let vm = MCPApprovalViewModel(clock: clock, makePanel: { _, _, _, canPersist, onAlwaysAllow, onAllowOnce, onDeny in
            callbacks.canPersist = canPersist
            callbacks.onAlwaysAllow = onAlwaysAllow
            callbacks.onAllowOnce = onAllowOnce
            callbacks.onDeny = onDeny
            return panel
        })
        return (vm, panel, callbacks)
    }

    /// Waits (yielding, never sleeping) until `present`'s synchronous setup — including the
    /// `makePanel` call — has run inside the spawned `Task`.
    func waitForCallbacks(_ callbacks: Callbacks) async {
        for _ in 0..<10_000 where callbacks.onAllowOnce == nil { await Task.yield() }
    }

    @Test("present() shows the panel and forwards the caller's canPersist verbatim")
    func presentShowsPanel() async throws {
        let h = harness(clock: FakeClock())
        let task = Task { await h.vm.present(identity: identity, tools: ["dictate"], canPersist: true) }
        await waitForCallbacks(h.callbacks)
        #expect(h.panel.shown)
        #expect(h.callbacks.canPersist == true)
        h.callbacks.onDeny?()
        _ = await task.value
    }

    @Test("canPersist: false (an unresolved peer) is forwarded through unchanged")
    func presentForwardsCanPersistFalse() async throws {
        let h = harness(clock: FakeClock())
        let task = Task { await h.vm.present(identity: identity, tools: ["dictate"], canPersist: false) }
        await waitForCallbacks(h.callbacks)
        #expect(h.callbacks.canPersist == false)
        h.callbacks.onDeny?()
        _ = await task.value
    }

    @Test("Always allow resolves .allow and hides the panel")
    func alwaysAllowResolvesAllow() async throws {
        let h = harness(clock: FakeClock())
        let task = Task { await h.vm.present(identity: identity, tools: ["dictate"], canPersist: true) }
        await waitForCallbacks(h.callbacks)
        h.callbacks.onAlwaysAllow?()
        #expect(await task.value == .allow)
        #expect(h.panel.hidden)
    }

    @Test("Allow once resolves .allowOnce (session-only, never persisted) and hides the panel")
    func allowOnceResolvesAllowOnce() async throws {
        let h = harness(clock: FakeClock())
        let task = Task { await h.vm.present(identity: identity, tools: ["dictate"], canPersist: true) }
        await waitForCallbacks(h.callbacks)
        h.callbacks.onAllowOnce?()
        #expect(await task.value == .allowOnce)
        #expect(h.panel.hidden)
    }

    @Test("Deny resolves .deny and hides the panel")
    func denyResolvesDeny() async throws {
        let h = harness(clock: FakeClock())
        let task = Task { await h.vm.present(identity: identity, tools: ["dictate"], canPersist: true) }
        await waitForCallbacks(h.callbacks)
        h.callbacks.onDeny?()
        #expect(await task.value == .deny)
        #expect(h.panel.hidden)
    }

    @Test("no button pressed within 60 s (on the injected clock) resolves .deny and hides the panel")
    func timeoutResolvesDeny() async throws {
        let clock = FakeClock()
        let h = harness(clock: clock)
        let task = Task { await h.vm.present(identity: identity, tools: ["dictate"], canPersist: true) }
        await waitForCallbacks(h.callbacks)
        await clock.waitForSleepers(1)
        await clock.advance(by: MCPApprovalViewModel.timeout)
        #expect(await task.value == .deny)
        #expect(h.panel.hidden)
    }

    @Test("a button press before the timeout wins — the timeout never fires afterwards")
    func buttonBeforeTimeoutWins() async throws {
        let clock = FakeClock()
        let h = harness(clock: clock)
        let task = Task { await h.vm.present(identity: identity, tools: ["dictate"], canPersist: true) }
        await waitForCallbacks(h.callbacks)
        await clock.waitForSleepers(1)
        h.callbacks.onAlwaysAllow?()
        #expect(await task.value == .allow)
        // Advancing well past the timeout afterwards must not change anything — the continuation
        // already resumed once; a second resume would be a runtime crash if `finish` didn't guard it.
        await clock.advance(by: MCPApprovalViewModel.timeout * 2)
    }
}
