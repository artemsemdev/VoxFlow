import Foundation

/// One-shot gate: `wait()` suspends until `open()` was called (returns at once afterwards).
public actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public init() {}
    public func open() { isOpen = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
    public func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
