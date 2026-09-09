import AppKit

/// The `MenuBarExtra` status-bar icon (design MB-01/MB-02 status bar) — three vertical rounded
/// bars, drawn in code (ruling 6: "until #141 ships the icon asset") rather than a shipped asset.
/// `isTemplate = true` so AppKit recolours it for light/dark menu bars and the "active" (dark
/// background) state automatically, the same way a template `systemImage` would have.
enum MenuBarGlyph {
    /// 18×18 pt, matching the menu bar's usual glyph size. Bar heights 8/14/10 pt (short-tall-short,
    /// suggesting a waveform) in a 3 pt width, 2 pt gutter, centred in the canvas.
    static let image: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let barWidth: CGFloat = 3
        let gutter: CGFloat = 2
        let heights: [CGFloat] = [8, 14, 10]
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gutter
            var x = rect.minX + (rect.width - totalWidth) / 2
            for height in heights {
                let y = rect.minY + (rect.height - height) / 2
                let bar = NSRect(x: x, y: y, width: barWidth, height: height)
                NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
                x += barWidth + gutter
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}
