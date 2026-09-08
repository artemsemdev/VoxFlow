import SwiftUI

/// The seven sidebar destinations of the main window (design 1c, MW-01…06, ST-01).
/// Order is the order in the sidebar and the ⌘1…⌘7 shortcuts (design 3d, "Main window").
enum SidebarPage: String, CaseIterable, Identifiable {
    case home, history, dictionary, snippets, styles, files, settings

    static let `default`: SidebarPage = .home

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .history: "History"
        case .dictionary: "Dictionary"
        case .snippets: "Snippets"
        case .styles: "Styles"
        case .files: "Files"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .history: "clock"
        case .dictionary: "character.book.closed"
        case .snippets: "text.insert"
        case .styles: "textformat"
        case .files: "doc.text"
        case .settings: "gearshape"
        }
    }

    /// 1-based position, used for ⌘1…⌘7. Explicit so inserting a page is a deliberate change.
    var shortcutNumber: Int {
        switch self {
        case .home: 1
        case .history: 2
        case .dictionary: 3
        case .snippets: 4
        case .styles: 5
        case .files: 6
        case .settings: 7
        }
    }

    /// The digit key for the ⌘-shortcut. Only single digits are valid key equivalents.
    var keyEquivalent: KeyEquivalent {
        precondition((1...9).contains(shortcutNumber), "⌘-digit shortcuts stop at 9")
        return KeyEquivalent(Character(String(shortcutNumber)))
    }
}
