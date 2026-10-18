import Foundation

/// Immutable capture identity and a synchronous validity check used immediately before an
/// external write. Cancellation invalidates this context even while an actor hop is pending.
public struct LiveInsertionContext: Sendable {
    public let id = UUID()
    private let active: @Sendable () -> Bool
    public init(isActive: @escaping @Sendable () -> Bool) { active = isActive }
    public var isActive: Bool { !Task.isCancelled && active() }
}

/// Optional capability: cumulative previews and the final result share one owned text range.
/// Updates never write to the clipboard. Losing ownership disables writes until the next capture;
/// finish copies the full final result once. Invalid contexts perform no external writes.
public protocol LiveTextInserting: TextInserting {
    func beginLiveInsertion(_ context: LiveInsertionContext) async
    func updateLiveInsertion(_ text: String, context: LiveInsertionContext) async
    func finishLiveInsertion(_ text: String, cursorOffset: Int?, context: LiveInsertionContext) async -> InsertionResult?
    func cancelLiveInsertion(_ context: LiveInsertionContext) async
}

public extension LiveTextInserting {
    func cancelLiveInsertion(_ context: LiveInsertionContext) async {}
}
