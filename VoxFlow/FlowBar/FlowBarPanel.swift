import AppKit
import SwiftUI

/// The floating, non-activating panel that hosts `FlowBarView` (design 1a: "Floating pill,
/// bottom-center of the active display"). Sits above full-screen apps and Stage Manager, on every
/// Space, and never steals key focus or activates VoxFlow.
///
/// Mounted once with the coordinator-backed `FlowBarView` — that view re-reads the coordinator on
/// every SwiftUI render (see `FlowBarView.Source`), so `NSHostingView` re-renders on its own as the
/// state changes; this class only needs to keep the panel's frame in sync with the pill's size
/// (`reflow`, driven by the hosting view's own frame-change notifications) and to show/hide it.
@MainActor
final class FlowBarPanel: NSPanel, FlowBarPanelling {
    private let hostingView: NSHostingView<FlowBarView>

    init(rootView: FlowBarView) {
        hostingView = NSHostingView(rootView: rootView)
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                    backing: .buffered, defer: true)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false

        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.postsFrameChangedNotifications = true
        contentView = hostingView
        reflow()

        // Not retained: the block only weak-captures `self`, so it safely no-ops once the panel
        // (and the `hostingView` it observes) are gone — nothing to remove in a `deinit`.
        _ = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: hostingView, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reflow() }
        }
    }

    /// Re-positions on whichever screen currently holds the key window, keeping the fixed left
    /// edge / growing-right feel (design 2a) as `FlowBarView`'s content — and so the pill's size —
    /// changes.
    private func reflow() {
        present(on: NSScreen.main ?? NSScreen.screens.first)
    }

    /// Bottom-center of `screen`'s visible frame, 24 pt above the dock/edge (design 1a).
    func present(on screen: NSScreen) {
        let size = hostingView.fittingSize
        let origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 24)
        setFrame(NSRect(origin: origin, size: size), display: isVisible)
    }

    private func present(on screen: NSScreen?) {
        guard let screen else { return }
        present(on: screen)
    }

    // MARK: - FlowBarPanelling

    override var isVisible: Bool { alphaValue > 0 && super.isVisible }

    func show() {
        guard !(super.isVisible && alphaValue > 0) else { return }
        let target = frame
        alphaValue = 0
        // Scale in from 98% so the pill settles into place rather than popping.
        setFrame(target.insetBy(dx: target.width * 0.01, dy: target.height * 0.01), display: false)
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
            animator().setFrame(target, display: true)
        }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in self?.orderOut(nil) }
        })
    }
}
