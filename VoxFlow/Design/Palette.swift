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

    // MARK: - Flow Bar HUD (design 1a/2a: dark floating pill material)

    /// The pill's dark HUD material — near-black, slightly translucent.
    static let hudBackground = Color(white: 0.11).opacity(0.92)
    /// Title text on the pill.
    static let hudText = Color.white
    /// Dimmed subtitle/timer/chip text on the pill.
    static let hudSecondary = Color.white.opacity(0.6)
    /// The recording dot and error dot (FB-02, FB-07).
    static let recording = Color(red: 1, green: 69 / 255, blue: 58 / 255)   // #ff453a
    /// The warning dot (FB-05, FB-08).
    static let amber = Color(red: 1, green: 214 / 255, blue: 10 / 255)      // #ffd60a
}
