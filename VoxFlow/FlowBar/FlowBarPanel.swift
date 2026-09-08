import AppKit
import SwiftUI

/// The floating, non-activating panel that hosts `FlowBarView` (design 1a: "Floating pill,
/// bottom-center of the active display"). Sits above full-screen apps and Stage Manager, on every
/// Space, and never steals key focus or activates VoxFlow.
///
/// Mounted once with the coordinator-backed `FlowBarView` — that view re-reads the coordinator on
/// every SwiftUI render (see `FlowBarView.Source`), so the hosting controller re-renders on its own
/// as the state changes. Sizing is `NSHostingController.sizingOptions = [.intrinsicContentSize]`,
/// Apple's own documented mechanism for a window that tracks its SwiftUI content's ideal size —
/// preferred over hand-rolling it from a bare `NSHostingView`'s `fittingSize` plus a manual
/// `NSView.frameDidChangeNotification` observer, which depends on Auto Layout constraints this
/// borderless panel never installs and so may not fire reliably.
@MainActor
final class FlowBarPanel: NSPanel, FlowBarPanelling {
    private let hostingController: NSHostingController<FlowBarView>
    /// The x-origin established the last time the pill was (re)shown — held fixed across content
    /// growth so the pill grows to the *right*, left edge pinned (design 2a "ширина растёт вправо,
    /// левый край фиксирован"). Cleared on `show()` so each fresh appearance re-centers on the
    /// current screen (design 3d).
    private var leftEdgeX: CGFloat?
    /// Bumped by both `show()` and `hide()`; a `hide()`'s fade-out completion only `orderOut`s if
    /// this hasn't moved on since — the mechanism that makes `hide()` cancellable (a `show()` mid-fade
    /// bumps it, so the stale completion becomes a no-op instead of hiding a panel that was just
    /// re-shown).
    private var generation = 0
    /// True from the moment `hide()` is called until either its fade completes and orders out, or a
    /// `show()` cancels it — `isVisible` reports `false` while this is true even though the window is
    /// technically still on-screen and fading, so `FlowBarPresenter` sees "not visible" and calls
    /// `show()` promptly instead of skipping it (the root cause of the fixed bug: AppKit's own
    /// `isVisible` stays true for the whole fade, until `orderOut` actually runs).
    private var isHiding = false
    /// Suppressed while `show()`'s own scale-in animates the frame, so that its intermediate frames
    /// don't each re-trigger `reflow()` via `NSWindow.didResizeNotification` and cut the animation short.
    private var suppressReflow = false

    init(rootView: FlowBarView) {
        hostingController = NSHostingController(rootView: rootView)
        hostingController.sizingOptions = [.intrinsicContentSize]
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

        contentViewController = hostingController
        reflow()

        // Not retained/removed in a `deinit`: `self` (a `@MainActor`-isolated class) can't be safely
        // touched from `deinit`, which AppKit/Swift always runs non-isolated — the block only
        // weak-captures `self`, so once this (one long-lived, app-lifetime) panel is gone the block
        // becomes a harmless no-op; the single leftover registration entry is a bounded, one-time cost.
        _ = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: self, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reflow() }
        }
    }

    /// Re-derives the frame from the hosting controller's current (auto-updated) size and
    /// re-positions per `present(on:)`. Driven by `NSWindow.didResizeNotification`, which fires
    /// reliably for *any* frame change (ours or the content-driven auto-resize) — unlike observing
    /// the hosting view directly.
    private func reflow() {
        guard !suppressReflow, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        present(on: screen)
    }

    /// Bottom-center of `screen`'s visible frame on first presentation (`leftEdgeX == nil`, design
    /// 1a: `midX - width/2`, `minY + 24`); afterwards keeps the established left edge fixed as the
    /// pill's width changes, so it only grows right (design 2a).
    func present(on screen: NSScreen) {
        let size = frame.size
        let x = leftEdgeX ?? (screen.visibleFrame.midX - size.width / 2)
        leftEdgeX = x
        let origin = NSPoint(x: x, y: screen.visibleFrame.minY + 24)
        guard origin != frame.origin else { return }
        setFrame(NSRect(origin: origin, size: size), display: super.isVisible)
    }

    // MARK: - FlowBarPanelling

    /// Not AppKit's own on-screen/ordering flag (`super.isVisible`, which this deliberately narrows):
    /// also false while a `hide()` fade is in flight, so `FlowBarPresenter` — which gates every
    /// `show()` call on this — reacts immediately rather than waiting for the fade to finish.
    override var isVisible: Bool { super.isVisible && !isHiding }

    func show() {
        generation += 1
        isHiding = false
        leftEdgeX = nil
        reflow()
        let target = frame

        suppressReflow = true
        // Reset alpha directly (not via `.animator()`) so it's guaranteed to read back as `1`
        // synchronously right after `show()` returns — cancelling an in-flight `hide()` fade
        // must leave the pill immediately, verifiably fully opaque, not mid-interpolation.
        alphaValue = 1
        // Scale in from 98% so the pill settles into place rather than popping; only the frame
        // animates here, not the alpha.
        setFrame(target.insetBy(dx: target.width * 0.01, dy: target.height * 0.01), display: false)
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            Task { @MainActor in self?.suppressReflow = false }
        })
    }

    func hide() {
        generation += 1
        let myGeneration = generation
        isHiding = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == myGeneration else { return }
                self.isHiding = false
                self.orderOut(nil)
            }
        })
    }
}
