import SwiftUI

/// A small pill-shaped keyboard glyph. `FlowBarView`'s dark HUD "fn" trailing pill (design 2a) and
/// Settings › Hotkeys' shortcut display (ST-02) share this shape in two color styles — extracted
/// here (out of `FlowBarView`, which used to own a private copy) so both can reuse it.
struct KeycapView: View {
    /// `.dark`: white-on-translucent, for the Flow Bar's dark HUD material — reproduces
    /// `FlowBarView`'s original private `keycap(_:)` exactly. `.system`: adaptive light/dark, for a
    /// keycap sitting on a normal (non-HUD) Settings row.
    enum Style { case dark, system }

    let text: String
    var style: Style = .system

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(foreground)
            .fixedSize()
            .frame(minWidth: style == .system ? 20 : 0)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5).fill(fill)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(border, lineWidth: 1))
            )
    }

    private var fill: Color {
        switch style {
        case .dark: Color.white.opacity(0.16)
        case .system: Color(nsColor: .controlBackgroundColor)
        }
    }
    private var border: Color {
        switch style {
        case .dark: Color.white.opacity(0.2)
        case .system: Color.primary.opacity(0.15)
        }
    }
    private var foreground: Color {
        switch style {
        case .dark: Palette.hudText.opacity(0.85)
        case .system: Color.primary.opacity(0.85)
        }
    }
}
