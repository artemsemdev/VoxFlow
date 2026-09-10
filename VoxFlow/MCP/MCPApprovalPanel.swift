import AppKit
import SwiftUI

/// ST-06a: the floating "wants to use VoxFlow" client-request panel — copies `MenuBarHintPanel`'s
/// non-activating `NSPanel` shape (never steals key focus or brings VoxFlow forward) for the same
/// reason: it has to appear even when the main window is closed, since the MCP server can receive
/// a client's very first request at any time.
@MainActor
final class MCPApprovalPanel: NSPanel {
    private static let panelSize = NSSize(width: 340, height: 280)

    init(name: String, pid: Int32?, tools: [String], canPersist: Bool,
         onAlwaysAllow: @escaping () -> Void, onAllowOnce: @escaping () -> Void, onDeny: @escaping () -> Void) {
        let hosting = NSHostingController(rootView: MCPApprovalContentView(
            title: MCPApprovalCopy.title(name: name),
            message: MCPApprovalCopy.body(tools: tools),
            processLine: MCPApprovalCopy.processLine(name: name, pid: pid),
            canPersist: canPersist,
            onAlwaysAllow: onAlwaysAllow, onAllowOnce: onAllowOnce, onDeny: onDeny))
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
        positionCentered()
    }

    /// Centered on the active display — unlike `MenuBarHintPanel` (which points at a specific
    /// screen corner near the menu bar icon), ST-06a is a security-relevant decision with nothing
    /// on screen to point at, and the canvas draws it in the same centered-card style as every other
    /// alert (ST-06r, SYS-DISK, MW-06c) — so it gets the position to match, on top of the same
    /// non-activating `NSPanel` shape.
    private func positionCentered() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let x = screen.visibleFrame.midX - Self.panelSize.width / 2
        let y = screen.visibleFrame.midY - Self.panelSize.height / 2
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    func show() { orderFrontRegardless() }
    func hide() { orderOut(nil) }
}

/// Satisfies `MCPApprovalPanelPresenting` (`MCPApprovalViewModel.swift`) with the real panel's own
/// `show()`/`hide()` — trivial, since the panel already has exactly that shape.
extension MCPApprovalPanel: MCPApprovalPanelPresenting {}

/// ST-06a's content: icon, title, body, process line, and the decision buttons — centered, matching
/// the canvas's alert-card family (SYS-DISK, MW-06c, ST-06r all share this icon-plus-centered-text
/// layout; `MCPRegenerateAlertPreview`, formerly in `SettingsRenderTests`, now `MCPRenderTests`, is
/// the same style). Not `private` — `MCPRenderTests` renders it directly for the design-fidelity
/// comparison. Views hold no rules: every string here is handed in already-built by
/// `MCPApprovalCopy` (`MCPApprovalViewModel.swift`); `canPersist` (`MCPApprovalPresenting`'s own
/// doc, `MCPToolRunner.swift`) is the one rule this view does act on directly — hiding "Always
/// allow" is the actual mechanism behind "the presenter must not offer Always allow" for an
/// unresolved ("Unknown app") peer.
struct MCPApprovalContentView: View {
    let title: String
    let message: String
    let processLine: String
    let canPersist: Bool
    let onAlwaysAllow: () -> Void
    let onAllowOnce: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 22))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(processLine)
                .font(.system(size: 11).monospaced())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(spacing: 6) {
                if canPersist {
                    Button("Always allow", action: onAlwaysAllow)
                        .buttonStyle(.borderedProminent).controlSize(.small).frame(maxWidth: .infinity)
                }
                if canPersist {
                    Button("Allow once", action: onAllowOnce)
                        .buttonStyle(.bordered).controlSize(.small).frame(maxWidth: .infinity)
                } else {
                    // No "Always allow" above (an unresolved peer, `canPersist == false`) — "Allow
                    // once" is the closest thing to a primary action, so it takes the prominent style.
                    Button("Allow once", action: onAllowOnce)
                        .buttonStyle(.borderedProminent).controlSize(.small).frame(maxWidth: .infinity)
                }
                Button("Deny", action: onDeny)
                    .buttonStyle(.bordered).controlSize(.small).tint(.red).frame(maxWidth: .infinity)
            }
            .padding(.top, 4)
        }
        .padding(18)
        .frame(width: 340)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
