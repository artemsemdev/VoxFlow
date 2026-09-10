import Foundation
import VoxFlowCore
import VoxFlowMCP

/// ST-06a copy — pure and testable without ever building a window (`MCPApprovalViewModelTests`
/// "copy verbatim"). Characters matched against the rendered canvas (`canvas.pdf` page 5), not the
/// task brief's markdown, where they differ: curly quotes around the app name, `·` (middle dot)
/// before the loopback address.
enum MCPApprovalCopy {
    static func title(name: String) -> String { "\u{201C}\(name)\u{201D} wants to use VoxFlow" }

    static func body(tools: [String]) -> String {
        "A local app connected to the MCP server with a valid token. It can use: \(tools.joined(separator: ", "))."
    }

    static func processLine(name: String, pid: Int32?) -> String {
        "Process: \(name) (pid \(pid.map(String.init) ?? "unknown")) · 127.0.0.1"
    }
}

/// Abstraction over the real `MCPApprovalPanel` window, so `MCPApprovalViewModel` is testable
/// without ever spinning up a real `NSPanel`.
@MainActor
protocol MCPApprovalPanelPresenting: AnyObject {
    func show()
    func hide()
}

/// ST-06a: bridges `MCPToolRunner`'s `async` `MCPApprovalPresenting` seam (defined in
/// `MCPToolRunner.swift` — not this task's to redefine) to a real floating panel and back.
/// `present` suspends until a button is pressed or `Self.timeout` elapses, whichever comes first;
/// either way the continuation resumes exactly once and the panel is always hidden afterwards — a
/// panel dismissed without a choice (the timeout path) resolves `.deny` rather than leaking the
/// continuation or leaving a stray window on screen. The actual per-presentation state and control
/// flow lives in `PresentationSession` (below), not here — see its own doc for why.
///
/// `@MainActor final class … : MCPApprovalPresenting, Sendable` — the same reasoning
/// `MCPToolRunner`'s own doc comment gives for itself: every stored property here is `Sendable`
/// (`clock`, `makePanel`). `MCPApprovalPresenting` requires `Sendable` so `MCPToolRunner` can hold
/// this as `any MCPApprovalPresenting`; every call always resumes onto the main actor (via the
/// implicit `await` hop) before touching any main-actor state.
@MainActor
final class MCPApprovalViewModel: MCPApprovalPresenting, Sendable {
    /// Ruling 5: an unanswered panel resolves `.deny` after this long.
    static let timeout: TimeInterval = 60

    private let clock: any MonotonicClock
    private let makePanel: @MainActor (_ name: String, _ pid: Int32?, _ tools: [String], _ canPersist: Bool,
                                        _ onAlwaysAllow: @escaping () -> Void, _ onAllowOnce: @escaping () -> Void,
                                        _ onDeny: @escaping () -> Void) -> any MCPApprovalPanelPresenting

    init(clock: any MonotonicClock = SystemMonotonicClock(),
         makePanel: @escaping @MainActor (_ name: String, _ pid: Int32?, _ tools: [String], _ canPersist: Bool,
                                           _ onAlwaysAllow: @escaping () -> Void, _ onAllowOnce: @escaping () -> Void,
                                           _ onDeny: @escaping () -> Void) -> any MCPApprovalPanelPresenting
             = { name, pid, tools, canPersist, onAlwaysAllow, onAllowOnce, onDeny in
                 MCPApprovalPanel(name: name, pid: pid, tools: tools, canPersist: canPersist,
                                  onAlwaysAllow: onAlwaysAllow, onAllowOnce: onAllowOnce, onDeny: onDeny)
             }) {
        self.clock = clock
        self.makePanel = makePanel
    }

    /// "Always allow" → `.allow` (`MCPToolRunner.authorize` persists this to `mcp_clients` when
    /// `canPersist`, degrading to a session-only grant otherwise — see that method's own doc).
    /// "Allow once" → `.allowOnce`, always session-only, never persisted. `canPersist` is passed
    /// straight through to `MCPApprovalContentView`, which is what actually hides the "Always
    /// allow" button for an unresolved ("Unknown app") peer — this bridge itself makes no decision
    /// about which buttons to offer. A fresh `PresentationSession` per call means two concurrent
    /// presentations (different clients) never share mutable state.
    func present(identity: MCPClientIdentity, tools: [String], canPersist: Bool) async -> MCPClientDecision {
        let session = PresentationSession(clock: clock, makePanel: makePanel)
        return await session.run(name: identity.name, pid: identity.pid, tools: tools, canPersist: canPersist)
    }
}

/// One in-flight ST-06a presentation's mutable state, factored into a real `@MainActor` object
/// rather than a nested closure/local-function tangle inside `present`: `finish` calls
/// `panel?.hide()` (an `@MainActor` member), and as an ordinary instance method on an `@MainActor`
/// class that call is unambiguously same-actor and type-checks outright — unlike a local `func`
/// nested inside `withCheckedContinuation`'s closure, whose isolation the compiler could not
/// reliably infer through that much nesting (confirmed empirically while building this: the direct
/// calls in the closure's own body type-checked fine, but the same call one level down inside a
/// nested `func` did not).
@MainActor
private final class PresentationSession {
    private let clock: any MonotonicClock
    private let makePanel: @MainActor (_ name: String, _ pid: Int32?, _ tools: [String], _ canPersist: Bool,
                                        _ onAlwaysAllow: @escaping () -> Void, _ onAllowOnce: @escaping () -> Void,
                                        _ onDeny: @escaping () -> Void) -> any MCPApprovalPanelPresenting
    private var resumed = false
    private var panel: (any MCPApprovalPanelPresenting)?
    private var timeoutTask: Task<Void, Never>?

    init(clock: any MonotonicClock,
         makePanel: @escaping @MainActor (_ name: String, _ pid: Int32?, _ tools: [String], _ canPersist: Bool,
                                           _ onAlwaysAllow: @escaping () -> Void, _ onAllowOnce: @escaping () -> Void,
                                           _ onDeny: @escaping () -> Void) -> any MCPApprovalPanelPresenting) {
        self.clock = clock
        self.makePanel = makePanel
    }

    func run(name: String, pid: Int32?, tools: [String], canPersist: Bool) async -> MCPClientDecision {
        await withCheckedContinuation { continuation in
            begin(name: name, pid: pid, tools: tools, canPersist: canPersist, continuation: continuation)
        }
    }

    /// Builds and shows the panel, and arms the timeout race. Each button closure hops through its
    /// own `Task { @MainActor in … }` (matching `AppServices`' own weak-attach sink pattern, e.g.
    /// `HistorySavedSink.notify()`) rather than calling `finish` directly — the same reasoning as
    /// this whole type's existence: a call from inside an inline `() -> Void` closure passed to
    /// `makePanel` doesn't reliably type-check as same-actor without it.
    private func begin(name: String, pid: Int32?, tools: [String], canPersist: Bool,
                        continuation: CheckedContinuation<MCPClientDecision, Never>) {
        let panel = makePanel(name, pid, tools, canPersist,
            { [weak self] in Task { @MainActor in self?.finish(.allow, continuation: continuation) } },
            { [weak self] in Task { @MainActor in self?.finish(.allowOnce, continuation: continuation) } },
            { [weak self] in Task { @MainActor in self?.finish(.deny, continuation: continuation) } })
        self.panel = panel
        panel.show()

        timeoutTask = Task { @MainActor [weak self, clock] in
            try? await clock.sleep(for: MCPApprovalViewModel.timeout)
            guard !Task.isCancelled, let self else { return }
            self.finish(.deny, continuation: continuation)
        }
    }

    /// Guarded by `resumed` so exactly one of {a button, the timeout} ever resumes `continuation` —
    /// whichever arrives second is a no-op, never a double-resume crash.
    private func finish(_ decision: MCPClientDecision, continuation: CheckedContinuation<MCPClientDecision, Never>) {
        guard !resumed else { return }
        resumed = true
        timeoutTask?.cancel()
        panel?.hide()
        continuation.resume(returning: decision)
    }
}
