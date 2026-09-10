import ServiceManagement

/// Registers/unregisters VoxFlow as a login item (design ST-01 "Launch at login"), behind a
/// protocol so `GeneralViewModelTests` can fake both the read and the (throwing) write without
/// touching the real `SMAppService` — which in a sandboxed test run reliably fails, the exact
/// failure `GeneralViewModel`'s snap-back (3d "Toggles") needs to exercise.
protocol LoginItemControlling: Sendable {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

/// Production `LoginItemControlling`: `SMAppService.mainApp`, the modern (macOS 13+) replacement
/// for `SMLoginItemSetEnabled`. `register()`/`unregister()` both throw synchronously — no
/// completion handler to bridge, unlike the older API.
struct SMLoginItem: LoginItemControlling {
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
