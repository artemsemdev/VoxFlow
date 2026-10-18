import SwiftUI

/// Wires the live `MenuBarViewModel` (via `MenuBarServices`) into `MenuBarView` — the
/// `MenuBarExtra` scene's content (design MB-01/MB-02). `AppServices`/`SettingsServices` aren't
/// injected via `.environment(_:)` into the `MenuBarExtra` scene, so this reads `MenuBarServices.shared`
/// directly, same as `SettingsPage` reads `SettingsServices.shared`.
struct MenuBarContent: View {
    var body: some View {
        MenuBarView(viewModel: MenuBarServices.shared.viewModel)
    }
}

enum MainWindowID {
    static let main = "main"
}
