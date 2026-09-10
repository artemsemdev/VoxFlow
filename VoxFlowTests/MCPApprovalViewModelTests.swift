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
        #expect(MCPApprovalCopy.processLine(name: "Cursor", pid: 4812, path: "") == "Process: Cursor (pid 4812) · 127.0.0.1")
    }

    @Test("a single enabled tool still reads naturally")
    func singleTool() {
        #expect(MCPApprovalCopy.body(tools: ["dictate"]) ==
               "A local app connected to the MCP server with a valid token. It can use: dictate.")
    }

}

/// Review fix (Important #1): which buttons ST-06a offers — and their exact labels — is a rule, and
/// rules live in a tested type, not `MCPApprovalContentView`. `MCPApprovalPanel` renders exactly
/// this list; the view holds no `canPersist` conditional of its own any more.
@Suite("MCPApprovalButtons")
struct MCPApprovalButtonsTests {
    @Test("canPersist: true offers the three canvas buttons, in canvas order, with verbatim labels")
    func canPersistTrueOffersAllThree() {
        let buttons = MCPApprovalButtons.offered(canPersist: true)
        #expect(buttons.map(\.label) == ["Always allow", "Allow once", "Deny"])
        #expect(buttons.map(\.decision) == [.allow, .allowOnce, .deny])
        #expect(buttons.map(\.id) == [.alwaysAllow, .allowOnce, .deny])
        // "Always allow" leads as the prominent (filled) action; "Allow once" and "Deny" don't.
        #expect(buttons.map(\.isProminent) == [true, false, false])
        #expect(buttons.map(\.isDestructive) == [false, false, true])
    }

    @Test("canPersist: false hides \"Always allow\" — only the session-scoped grant and Deny remain")
    func canPersistFalseHidesAlwaysAllow() {
        let buttons = MCPApprovalButtons.offered(canPersist: false)
        #expect(buttons.map(\.label) == ["Allow once", "Deny"])
        #expect(buttons.map(\.decision) == [.allowOnce, .deny])
        #expect(!buttons.contains { $0.id == .alwaysAllow })
        // With no "Always allow" to lead, "Allow once" becomes the prominent action instead.
        #expect(buttons.map(\.isProminent) == [true, false])
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

    /// Captures the arguments/closure `MCPApprovalViewModel.present` hands to `makePanel` —
    /// synchronously set by the time `present`'s first suspension point is reached, since
    /// `withCheckedContinuation`'s body (which calls `makePanel`) runs before any `await`.
    final class Callbacks {
        var canPersist: Bool?
        var onDecision: ((MCPClientDecision) -> Void)?
    }

    func harness(clock: any MonotonicClock) -> (vm: MCPApprovalViewModel, panel: FakePanel, callbacks: Callbacks) {
        let panel = FakePanel()
        let callbacks = Callbacks()
        let vm = MCPApprovalViewModel(clock: clock, makePanel: { _, _, _, _, canPersist, onDecision in
            callbacks.canPersist = canPersist
            callbacks.onDecision = onDecision
            return panel
        })
        return (vm, panel, callbacks)
    }

    /// Waits (yielding, never sleeping) until `present`'s synchronous setup — including the
    /// `makePanel` call — has run inside the spawned `Task`.
    func waitForCallbacks(_ callbacks: Callbacks) async {
        for _ in 0..<10_000 where callbacks.onDecision == nil { await Task.yield() }
    }

    @Test("present() shows the panel and forwards the caller's canPersist verbatim")
    func presentShowsPanel() async throws {
        let h = harness(clock: FakeClock())
        let task = Task { await h.vm.present(identity: identity, tools: ["dictate"], canPersist: true) }
        await waitForCallbacks(h.callbacks)
        #expect(h.panel.shown)
        #expect(h.callbacks.canPersist == true)
        h.callbacks.onDecision?(.deny)
        _ = await task.value
    }

    @Test("canPersist: false (an unresolved peer) is forwarded through unchanged")
    func presentForwardsCanPersistFalse() async throws {
        let h = harness(clock: FakeClock())
        let task = Task { await h.vm.present(identity: identity, tools: ["dictate"], canPersist: false) }
        await waitForCallbacks(h.callbacks)
        #expect(h.callbacks.canPersist == false)
        h.callbacks.onDecision?(.deny)
        _ = await task.value
    }

    @Test("Always allow resolves .allow and hides the panel")
    func alwaysAllowResolvesAllow() async throws {
        let h = harness(clock: FakeClock())
        let task = Task { await h.vm.present(identity: identity, tools: ["dictate"], canPersist: true) }
        await waitForCallbacks(h.callbacks)
        h.callbacks.onDecision?(.allow)
        #expect(await task.value == .allow)
        #expect(h.panel.hidden)
    }

    @Test("Allow once resolves .allowOnce (session-only, never persisted) and hides the panel")
    func allowOnceResolvesAllowOnce() async throws {
        let h = harness(clock: FakeClock())
        let task = Task { await h.vm.present(identity: identity, tools: ["dictate"], canPersist: true) }
        await waitForCallbacks(h.callbacks)
        h.callbacks.onDecision?(.allowOnce)
        #expect(await task.value == .allowOnce)
        #expect(h.panel.hidden)
    }

    @Test("Deny resolves .deny and hides the panel")
    func denyResolvesDeny() async throws {
        let h = harness(clock: FakeClock())
        let task = Task { await h.vm.present(identity: identity, tools: ["dictate"], canPersist: true) }
        await waitForCallbacks(h.callbacks)
        h.callbacks.onDecision?(.deny)
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
        h.callbacks.onDecision?(.allow)
        #expect(await task.value == .allow)
        // Advancing well past the timeout afterwards must not change anything — the continuation
        // already resumed once; a second resume would be a runtime crash if `finish` didn't guard it.
        await clock.advance(by: MCPApprovalViewModel.timeout * 2)
    }

    // MARK: onApproved (review fix, Important #2)

    @Test("Always allow (the only decision that can persist) fires onApproved exactly once")
    func alwaysAllowFiresOnApproved() async throws {
        let h = harness(clock: FakeClock())
        var approvedCount = 0
        h.vm.onApproved = { approvedCount += 1 }
        let task = Task { await h.vm.present(identity: identity, tools: ["dictate"], canPersist: true) }
        await waitForCallbacks(h.callbacks)
        h.callbacks.onDecision?(.allow)
        _ = await task.value
        #expect(approvedCount == 1)
    }

    @Test("Allow once never fires onApproved — it's session-only, never persisted")
    func allowOnceNeverFiresOnApproved() async throws {
        let h = harness(clock: FakeClock())
        var approvedCount = 0
        h.vm.onApproved = { approvedCount += 1 }
        let task = Task { await h.vm.present(identity: identity, tools: ["dictate"], canPersist: true) }
        await waitForCallbacks(h.callbacks)
        h.callbacks.onDecision?(.allowOnce)
        _ = await task.value
        #expect(approvedCount == 0)
    }

    @Test("Deny never fires onApproved")
    func denyNeverFiresOnApproved() async throws {
        let h = harness(clock: FakeClock())
        var approvedCount = 0
        h.vm.onApproved = { approvedCount += 1 }
        let task = Task { await h.vm.present(identity: identity, tools: ["dictate"], canPersist: true) }
        await waitForCallbacks(h.callbacks)
        h.callbacks.onDecision?(.deny)
        _ = await task.value
        #expect(approvedCount == 0)
    }

    @Test("the timeout (never fires onApproved — it always resolves .deny)")
    func timeoutNeverFiresOnApproved() async throws {
        let clock = FakeClock()
        let h = harness(clock: clock)
        var approvedCount = 0
        h.vm.onApproved = { approvedCount += 1 }
        let task = Task { await h.vm.present(identity: identity, tools: ["dictate"], canPersist: true) }
        await waitForCallbacks(h.callbacks)
        await clock.waitForSleepers(1)
        await clock.advance(by: MCPApprovalViewModel.timeout)
        _ = await task.value
        #expect(approvedCount == 0)
    }

    // MARK: final review F5 — the process line

    @Test("the process line omits the pid entirely when resolution failed, rather than printing \"unknown\"")
    func processLineOmitsUnknownPid() {
        #expect(MCPApprovalCopy.processLine(name: "Unknown app", pid: nil, path: "") == "Process: Unknown app · 127.0.0.1")
    }

    @Test("the process line shows the executable path the grant is keyed on")
    func processLineShowsPath() {
        let line = MCPApprovalCopy.processLine(name: "Cursor", pid: 4812, path: "/Applications/Cursor.app/Contents/MacOS/Cursor")
        #expect(line == "Process: Cursor (pid 4812) · 127.0.0.1\n/Applications/Cursor.app/Contents/MacOS/Cursor")
    }
}
