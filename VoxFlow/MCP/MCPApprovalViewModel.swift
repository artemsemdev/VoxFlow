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

/// One ST-06a decision button: its label, which `MCPClientDecision` pressing it resolves, and how
/// it's styled. `MCPApprovalContentView` renders exactly the list `MCPApprovalButtons.offered(canPersist:)`
/// returns and holds no rule of its own about which buttons to show — review fix (Important #1):
/// "hide Always allow when canPersist is false" was previously a bare `if` inside the view (an
/// untested, security-relevant rule living in the wrong layer); it now lives here, in a pure,
/// directly tested function, per `MCPApprovalPresenting`'s own doc in `MCPToolRunner.swift` ("the
/// presenter must not offer Always allow" for an identity that can't persist an approval).
struct MCPApprovalButtonSpec: Identifiable, Equatable {
    enum Kind: Equatable { case alwaysAllow, allowOnce, deny }
    let id: Kind
    let label: String
    let decision: MCPClientDecision
    let isProminent: Bool
    let isDestructive: Bool
}

enum MCPApprovalButtons {
    /// Canvas order (page 5): "Always allow" (only when `canPersist`), "Allow once", "Deny".
    /// `canPersist == false` means `identity.path` didn't resolve (every such peer displays as the
    /// same "Unknown app" — persisting an approval for one would silently approve all of them, see
    /// `MCPApprovalPresenting`'s doc): with no "Always allow" to lead, "Allow once" — the closest
    /// thing to a primary action — takes the prominent (filled) style instead.
    static func offered(canPersist: Bool) -> [MCPApprovalButtonSpec] {
        var buttons: [MCPApprovalButtonSpec] = []
        if canPersist {
            buttons.append(MCPApprovalButtonSpec(id: .alwaysAllow, label: "Always allow", decision: .allow,
                                                 isProminent: true, isDestructive: false))
        }
        buttons.append(MCPApprovalButtonSpec(id: .allowOnce, label: "Allow once", decision: .allowOnce,
                                             isProminent: !canPersist, isDestructive: false))
        buttons.append(MCPApprovalButtonSpec(id: .deny, label: "Deny", decision: .deny,
                                             isProminent: false, isDestructive: true))
        return buttons
    }
}

/// Abstraction over the real `MCPApprovalPanel` window, so `MCPApprovalViewModel` is testable
/// without ever spinning up a real `NSPanel`.
@MainActor
protocol MCPApprovalPanelPresenting: AnyObject {
    func show()
    func hide()
}

/// What `MCPViewModel` observes to know a client was just approved — review fix (Important #2):
/// "Connected clients" previously only refreshed on page-appear, after `revoke(_:)`, and after
/// `confirmRegenerate()`; a client approved via ST-06a while Settings was already open never showed
/// up until the tab was re-entered. `MCPApprovalViewModel` conforms to this and fires `onApproved`
/// exactly when a decision that persists a grant (`.allow`) resolves — never for `.allowOnce`
/// (session-only, never written to `mcp_clients`) or `.deny`.
@MainActor
protocol MCPApprovalObserving: AnyObject {
    var onApproved: (() -> Void)? { get set }
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
/// (`clock`, `makePanel`) or, like `onApproved`, only ever set/read from this actor's serial
/// executor. `MCPApprovalPresenting` requires `Sendable` so `MCPToolRunner` can hold this as `any
/// MCPApprovalPresenting`; every call always resumes onto the main actor (via the implicit `await`
/// hop) before touching any main-actor state.
@MainActor
final class MCPApprovalViewModel: MCPApprovalPresenting, MCPApprovalObserving, Sendable {
    /// Ruling 5: an unanswered panel resolves `.deny` after this long.
    static let timeout: TimeInterval = 60

    /// Fired when (and only when) a presentation resolves `.allow` — see `MCPApprovalObserving`'s
    /// doc. Set once by `MCPViewModel` at construction (`AppServices.live()`), with a `[weak self]`
    /// capture back to it, so this never keeps a `MCPViewModel` alive past its own lifetime.
    var onApproved: (() -> Void)?

    private let clock: any MonotonicClock
    private let makePanel: @MainActor (_ name: String, _ pid: Int32?, _ tools: [String], _ canPersist: Bool,
                                        _ onDecision: @escaping (MCPClientDecision) -> Void) -> any MCPApprovalPanelPresenting

    init(clock: any MonotonicClock = SystemMonotonicClock(),
         makePanel: @escaping @MainActor (_ name: String, _ pid: Int32?, _ tools: [String], _ canPersist: Bool,
                                           _ onDecision: @escaping (MCPClientDecision) -> Void) -> any MCPApprovalPanelPresenting
             = { name, pid, tools, canPersist, onDecision in
                 MCPApprovalPanel(name: name, pid: pid, tools: tools, canPersist: canPersist, onDecision: onDecision)
             }) {
        self.clock = clock
        self.makePanel = makePanel
    }

    func present(identity: MCPClientIdentity, tools: [String], canPersist: Bool) async -> MCPClientDecision {
        let session = PresentationSession(clock: clock, makePanel: makePanel, onApproved: { [weak self] in self?.onApproved?() })
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
                                        _ onDecision: @escaping (MCPClientDecision) -> Void) -> any MCPApprovalPanelPresenting
    private let onApproved: () -> Void
    private var resumed = false
    private var panel: (any MCPApprovalPanelPresenting)?
    private var timeoutTask: Task<Void, Never>?

    init(clock: any MonotonicClock,
         makePanel: @escaping @MainActor (_ name: String, _ pid: Int32?, _ tools: [String], _ canPersist: Bool,
                                           _ onDecision: @escaping (MCPClientDecision) -> Void) -> any MCPApprovalPanelPresenting,
         onApproved: @escaping () -> Void) {
        self.clock = clock
        self.makePanel = makePanel
        self.onApproved = onApproved
    }

    func run(name: String, pid: Int32?, tools: [String], canPersist: Bool) async -> MCPClientDecision {
        await withCheckedContinuation { continuation in
            begin(name: name, pid: pid, tools: tools, canPersist: canPersist, continuation: continuation)
        }
    }

    /// Builds and shows the panel, and arms the timeout race. The one `onDecision` closure hops
    /// through its own `Task { @MainActor in … }` (matching `AppServices`' own weak-attach sink
    /// pattern, e.g. `HistorySavedSink.notify()`) rather than calling `finish` directly — the same
    /// reasoning as this whole type's existence: a call from inside an inline closure passed to
    /// `makePanel` doesn't reliably type-check as same-actor without it.
    private func begin(name: String, pid: Int32?, tools: [String], canPersist: Bool,
                        continuation: CheckedContinuation<MCPClientDecision, Never>) {
        let panel = makePanel(name, pid, tools, canPersist) { [weak self] decision in
            Task { @MainActor in self?.finish(decision, continuation: continuation) }
        }
        self.panel = panel
        panel.show()

        timeoutTask = Task { @MainActor [weak self, clock] in
            try? await clock.sleep(for: MCPApprovalViewModel.timeout)
            guard !Task.isCancelled, let self else { return }
            self.finish(.deny, continuation: continuation)
        }
    }

    /// Guarded by `resumed` so exactly one of {a button, the timeout} ever resumes `continuation` —
    /// whichever arrives second is a no-op, never a double-resume crash. `onApproved` fires only for
    /// `.allow` — never `.allowOnce` (session-only) or `.deny` — matching `MCPApprovalObserving`'s doc.
    private func finish(_ decision: MCPClientDecision, continuation: CheckedContinuation<MCPClientDecision, Never>) {
        guard !resumed else { return }
        resumed = true
        timeoutTask?.cancel()
        panel?.hide()
        if decision == .allow { onApproved() }
        continuation.resume(returning: decision)
    }
}
