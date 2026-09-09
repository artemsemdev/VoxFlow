import AppKit
import SwiftUI

/// MB-00 (design page 4): "VoxFlow lives here" — a small floating hint panel shown once, right
/// after onboarding finishes, pointing at the menu bar icon. Non-activating (never steals key focus
/// or brings VoxFlow forward) and placed at the top-right of the active display, just below the
/// menu bar, with a 12 pt inset — closest reachable position to "pointing at the icon" without
/// knowing the status item's exact frame (`NSStatusItem.button.window.frame` isn't reliably
/// available from here; see the task report).
@MainActor
final class MenuBarHintPanel: NSPanel {
    private static let panelSize = NSSize(width: 300, height: 110)

    init(onGotIt: @escaping () -> Void) {
        let hosting = NSHostingController(rootView: MenuBarHintView(onGotIt: onGotIt))
        super.init(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                    styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                    backing: .buffered, defer: true)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        contentViewController = hosting
        positionTopRight()
    }

    /// Top-right of the active display, 12 pt below the menu bar and 12 pt in from the right edge.
    private func positionTopRight() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let x = screen.visibleFrame.maxX - Self.panelSize.width - 12
        let y = screen.visibleFrame.maxY - Self.panelSize.height - 12
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    func show() { orderFrontRegardless() }
    func hide() { orderOut(nil) }
}

/// MB-00's content: title, body, and "Got it" — dark/light adaptive via `.regularMaterial`. Not
/// `private` — `MenuBarRenderTests` renders it directly for the MB-00 design-fidelity comparison.
struct MenuBarHintView: View {
    let onGotIt: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("VoxFlow lives here")
                .font(.system(size: 13, weight: .semibold))
            Text("Hold fn in any text field to dictate. Click this icon for stats, pause and settings.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Got it", action: onGotIt)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 300, height: 110, alignment: .topLeading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
