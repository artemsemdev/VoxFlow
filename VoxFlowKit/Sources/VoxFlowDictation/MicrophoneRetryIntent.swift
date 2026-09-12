import Foundation

/// Gesture intent retained while microphone ownership is unavailable. A claimed retry must run
/// fresh preflight before consuming its ticket; release/cancel invalidates that suspended work.
struct MicrophoneRetryIntent: Sendable {
    enum Input: Sendable { case fnDown, fnUp, shortcutDown(HotkeyMode), pushToTalkReleased, cancel }
    struct Activation: Sendable, Equatable {
        var mode: HotkeyMode?
        var fnIsDown: Bool
        var holdDelay: TimeInterval?
        var doubleTapDelay: TimeInterval?
    }
    struct Ticket: Sendable { fileprivate let id: UUID }
    private enum Gesture: Equatable, Sendable {
        case fn(downAt: TimeInterval, releasedAt: TimeInterval?)
        case resolved(HotkeyMode)
    }

    private let config: FlowBarConfig
    private var gesture: Gesture?
    private var offered = false
    private var pendingClaim: UUID?

    init(config: FlowBarConfig = FlowBarConfig()) { self.config = config }

    mutating func begin(mode: HotkeyMode?, at now: TimeInterval) {
        gesture = mode.map(Gesture.resolved) ?? .fn(downAt: now, releasedAt: nil)
        rearm()
    }

    mutating func update(_ input: Input, at now: TimeInterval) {
        expire(at: now)
        let previous = gesture
        switch (gesture, input) {
        case (_, .cancel): gesture = nil
        case (.fn(let down, nil), .fnUp):
            gesture = now - down >= config.holdThreshold ? nil : .fn(downAt: down, releasedAt: now)
        case (.fn(_, .some), .fnDown): gesture = .resolved(.handsFree)
        case (.resolved(.pushToTalk), .fnUp), (.resolved(.pushToTalk), .pushToTalkReleased):
            gesture = nil
        case (.fn(let down, nil), .pushToTalkReleased) where now - down >= config.holdThreshold:
            gesture = nil
        case (.resolved(.handsFree), .fnDown), (.resolved(.handsFree), .shortcutDown(.handsFree)):
            gesture = nil
        default: break
        }
        if gesture != previous { rearm() }
    }

    /// A fresh busy result may rearm the same still-live gesture after a consumed retry.
    /// Repeated free notifications must not call this: they share one offer and one ticket.
    mutating func rearm() { offered = false; pendingClaim = nil }

    mutating func claim(at now: TimeInterval) -> Ticket? {
        expire(at: now)
        guard gesture != nil, !offered else { return nil }
        let id = UUID()
        offered = true
        pendingClaim = id
        return Ticket(id: id)
    }

    /// Re-evaluate elapsed gesture time after preflight, without counting waiting time as audio.
    /// The driver starts capture at its current time and schedules only these remaining delays.
    mutating func consume(_ ticket: Ticket, at now: TimeInterval) -> Activation? {
        expire(at: now)
        guard pendingClaim == ticket.id, let gesture else { return nil }
        pendingClaim = nil
        switch gesture {
        case .resolved(let mode):
            return Activation(mode: mode, fnIsDown: mode == .pushToTalk, holdDelay: nil, doubleTapDelay: nil)
        case .fn(let down, nil):
            let remaining = config.holdThreshold - (now - down)
            return Activation(mode: remaining <= 0 ? .pushToTalk : nil, fnIsDown: true,
                              holdDelay: remaining > 0 ? remaining : nil, doubleTapDelay: nil)
        case .fn(_, let released?):
            return Activation(mode: nil, fnIsDown: false, holdDelay: nil,
                              doubleTapDelay: released + config.doubleTapWindow - now)
        }
    }

    var expiresAt: TimeInterval? {
        guard case .fn(_, let released?) = gesture else { return nil }
        return released + config.doubleTapWindow
    }

    private mutating func expire(at now: TimeInterval) {
        guard let deadline = expiresAt, now >= deadline else { return }
        gesture = nil
        rearm()
    }
}
