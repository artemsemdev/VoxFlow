import AppKit
import Carbon.HIToolbox

struct FrontmostApp: Sendable, Equatable { var name: String?; var bundleID: String? }

protocol FrontmostAppProviding: Sendable {
    func frontmostApp() -> FrontmostApp
    func secureInputEnabled() -> Bool
}

struct WorkspaceFrontmostApp: FrontmostAppProviding {
    func frontmostApp() -> FrontmostApp {
        let app = NSWorkspace.shared.frontmostApplication
        return FrontmostApp(name: app?.localizedName, bundleID: app?.bundleIdentifier)
    }
    func secureInputEnabled() -> Bool { IsSecureEventInputEnabled() }
}
