import SwiftUI

/// Colors from the design's Tweaks panel (accent options) and the brand's "on-device" green.
enum Palette {
    /// The green status dot shown on every surface (Flow Bar, menu bar, sidebar footer, Privacy).
    static let onDevice = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255) // #30d158, design status dot

    enum AccentName: String, CaseIterable {
        case blue, purple, pink, orange, green, graphite
    }

    static func accent(_ name: AccentName) -> Color {
        switch name {
        case .blue: Color(red: 0, green: 122 / 255, blue: 1)                    // #007aff
        case .purple: Color(red: 175 / 255, green: 82 / 255, blue: 222 / 255)   // #af52de
        case .pink: Color(red: 1, green: 45 / 255, blue: 85 / 255)              // #ff2d55
        case .orange: Color(red: 1, green: 149 / 255, blue: 0)                  // #ff9500
        case .green: Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255)     // #34c759
        case .graphite: Color(red: 110 / 255, green: 110 / 255, blue: 115 / 255) // #6e6e73
        }
    }
}
