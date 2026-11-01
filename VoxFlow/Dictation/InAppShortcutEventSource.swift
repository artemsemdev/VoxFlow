import AppKit

/// Receives only events dispatched to VoxFlow's own windows; no event tap or global monitor.
@MainActor
final class InAppShortcutEventSource: NSObject, ShortcutEventSource {
    private var monitor: Any?
    private var onLoss: (() -> Void)?
    var isRunning: Bool { monitor != nil }

    func start(handler: @escaping (ShortcutEvent) -> Bool, onLoss: @escaping () -> Void) {
        guard !isRunning else { return }
        self.onLoss = onLoss
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { event in
            guard let snapshot = Self.snapshot(event) else { return event }
            return handler(snapshot) ? nil : event
        }
        NotificationCenter.default.addObserver(self, selector: #selector(resignedActive),
            name: NSApplication.didResignActiveNotification, object: nil)
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        NotificationCenter.default.removeObserver(self)
        onLoss = nil
    }

    @objc private func resignedActive() {
        // A modifier/key release can go to another app. Finish the held gesture immediately.
        onLoss?()
    }

    static func snapshot(_ event: NSEvent) -> ShortcutEvent? {
        let kind: ShortcutEvent.Kind
        switch event.type {
        case .flagsChanged: kind = .flagsChanged
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        default: return nil
        }
        return ShortcutEvent(kind: kind, keyCode: kind == .flagsChanged ? nil : event.keyCode,
            flags: event.modifierFlags, timestamp: event.timestamp,
            isRepeat: kind == .keyDown && event.isARepeat)
    }
}
