import AppKit
import SwiftUI
import VoxFlowMCP

/// ST-06a: the floating "wants to use VoxFlow" client-request panel — copies `MenuBarHintPanel`'s
/// non-activating `NSPanel` shape (never steals key focus or brings VoxFlow forward) for the same
/// reason: it has to appear even when the main window is closed, since the MCP server can receive
/// a client's very first request at any time.
@MainActor
final class MCPApprovalPanel: NSPanel {
    private static let panelSize = NSSize(width: 340, height: 280)

    init(name: String, pid: Int32?, path: String, tools: [String], canPersist: Bool, onDecision: @escaping (MCPClientDecision) -> Void) {
        let hosting = NSHostingController(rootView: MCPApprovalContentView(
            title: MCPApprovalCopy.title(name: name),
            message: MCPApprovalCopy.body(tools: tools),
            processLine: MCPApprovalCopy.processLine(name: name, pid: pid, path: path),
            buttons: MCPApprovalButtons.offered(canPersist: canPersist),
            onDecision: onDecision))
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
/// layout). Not `private` — `MCPRenderTests` renders it directly for the design-fidelity comparison.
///
/// Review fix (Important #1): this view holds **no** rule about which buttons to offer or how to
/// style them — `buttons` arrives already resolved (`MCPApprovalButtons.offered(canPersist:)`,
/// tested directly in `MCPApprovalButtonsTests`); this just renders the list and forwards whichever
/// button's `decision` was pressed to `onDecision`. Every string is likewise handed in already-built
/// by `MCPApprovalCopy`.
struct MCPApprovalContentView: View {
    let title: String
    let message: String
    let processLine: String
    let buttons: [MCPApprovalButtonSpec]
    let onDecision: (MCPClientDecision) -> Void

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
                // Two branches, not one `.buttonStyle(isProminent ? .borderedProminent : .bordered)`:
                // `.bordered`/`.borderedProminent` are different concrete `ButtonStyle` types, which
                // a ternary can't unify (confirmed empirically — see the task report).
                ForEach(buttons) { spec in
                    if spec.isProminent {
                        Button(spec.label) { onDecision(spec.decision) }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                            .tint(spec.isDestructive ? .red : nil).frame(maxWidth: .infinity)
                    } else {
                        Button(spec.label) { onDecision(spec.decision) }
                            .buttonStyle(.bordered).controlSize(.small)
                            .tint(spec.isDestructive ? .red : nil).frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.top, 4)
        }
        .padding(18)
        .frame(width: 340)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
