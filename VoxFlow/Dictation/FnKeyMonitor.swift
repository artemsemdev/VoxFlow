import AppKit

/// Global fn / esc / any-key monitoring (ruling 1). Requires Accessibility trust; without it the
/// global monitors return nil and only our own windows deliver events.
@MainActor
final class FnKeyMonitor {
    private var decoder = FnKeyDecoder()
    private var monitors: [Any] = []
    private let onFn: (FnTransition) -> Void
    private let onEscape: () -> Void
    private let onAnyKey: () -> Void
    private let isHUDActive: () -> Bool

    init(
        onFn: @escaping (FnTransition) -> Void,
        onEscape: @escaping () -> Void,
        onAnyKey: @escaping () -> Void,
        isHUDActive: @escaping () -> Bool
    ) {
        self.onFn = onFn
        self.onEscape = onEscape
        self.onAnyKey = onAnyKey
        self.isHUDActive = isHUDActive
    }

    func start() {
        guard monitors.isEmpty else { return }
        let flags: (NSEvent) -> Void = { [weak self] event in
            guard let self, let t = self.decoder.decode(flags: event.modifierFlags) else { return }
            self.onFn(t)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { flags($0); return $0 }) { monitors.append(m) }
        let keys: (NSEvent) -> Void = { [weak self] event in
            guard let self, self.isHUDActive() else { return }
            if event.keyCode == 53 { self.onEscape() } else { self.onAnyKey() }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keys) { monitors.append(m) }
    }

    func stop() { monitors.forEach { NSEvent.removeMonitor($0) }; monitors.removeAll() }
}
