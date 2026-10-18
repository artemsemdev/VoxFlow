import AppKit

/// Settings › General "Appearance" choice (design ST-01: Light / Dark / System).
enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case light, dark, system

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .system: "System"
        }
    }
}

/// Applies `AppAppearance` to the running app, behind a protocol so `GeneralViewModelTests` can
/// fake it without touching the real `NSApp`. `@MainActor`: `NSApp.appearance` must be set on the
/// main thread, and `GeneralViewModel` (the only caller) is main-actor-isolated anyway.
@MainActor
protocol AppearanceApplying {
    func apply(_ appearance: AppAppearance)
}

/// Production `AppearanceApplying`: `NSApp.appearance` — `nil` defers to the system setting.
struct NSAppearanceApplier: AppearanceApplying {
    func apply(_ appearance: AppAppearance) {
        switch appearance {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system: NSApp.appearance = nil
        }
    }
}
