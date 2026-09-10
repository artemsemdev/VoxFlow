import AppKit
import SwiftUI

/// Settings › General "Flow Bar position" (design ST-01, ruling 4) — where `FlowBarPanel` anchors
/// the pill on the active display. `bottomCenter` matches design 1a and is the default.
enum FlowBarPosition: String, CaseIterable, Identifiable, Sendable {
    case bottomCenter, topCenter, bottomLeft, bottomRight

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bottomCenter: "Bottom center"
        case .topCenter: "Top center"
        case .bottomLeft: "Bottom left"
        case .bottomRight: "Bottom right"
        }
    }
}

/// Pure geometry behind `FlowBarPanel.present(on:)` — pulled out so `GeneralFlowBarPositionTests`
/// can check every position's origin without a real `NSScreen`. `leftEdgeX`, when non-nil, is the
/// x-anchor already established for the pill's current appearance (design 2a: "grows right, left
/// edge fixed") and is echoed straight back, exactly as `present(on:)` did before this existed.
enum FlowBarPositionMath {
    static func origin(size: CGSize, visibleFrame: CGRect, position: FlowBarPosition, leftEdgeX: CGFloat?) -> CGPoint {
        let x: CGFloat
        switch position {
        case .bottomCenter, .topCenter:
            x = leftEdgeX ?? (visibleFrame.midX - size.width / 2)
        case .bottomLeft:
            x = leftEdgeX ?? (visibleFrame.minX + 24)
        case .bottomRight:
            x = leftEdgeX ?? (visibleFrame.maxX - size.width - 24)
        }
        let y: CGFloat
        switch position {
        case .bottomCenter, .bottomLeft, .bottomRight:
            y = visibleFrame.minY + 24
        case .topCenter:
            y = visibleFrame.maxY - size.height - 24
        }
        return CGPoint(x: x, y: y)
    }
}

/// What applies a `FlowBarPosition` — `FlowBarPanel` in production (directly), `FlowBarPresenter`
/// by forwarding to its panel (see `FlowBarPresenter.swift`), a fake in `GeneralViewModelTests`.
@MainActor
protocol FlowBarPositioning: AnyObject {
    func apply(_ position: FlowBarPosition)
}

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
final class FlowBarPanel: NSPanel, FlowBarPanelling, FlowBarPositioning, NSWindowDelegate {
    private let hostingController: NSHostingController<FlowBarView>
    /// Set by `apply(_:)` (Settings › General) — read by `present(on:)` via `FlowBarPositionMath`.
    private var position: FlowBarPosition = .bottomCenter
    /// The x-origin established the last time the pill was (re)shown or moved to a new screen — held
    /// fixed across content growth so the pill grows to the *right*, left edge pinned (design 2a
    /// "ширина растёт вправо, левый край фиксирован"). Cleared on `show()` (each fresh appearance
    /// re-centers, design 3d) and whenever `anchoredScreen` changes underneath it (N4).
    private var leftEdgeX: CGFloat?
    /// The screen `leftEdgeX` was computed against — if the key window (and so the Flow Bar) moves to
    /// a different display mid-dictation, the old x-anchor is meaningless on the new screen's
    /// coordinate space and must be re-established there instead.
    private var anchoredScreen: NSScreen?
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
    /// Suppressed while `show()`'s own scale-in animates the frame, so its intermediate frames don't
    /// each re-trigger `reflow()` via `windowDidResize` and cut the animation short.
    private var suppressReflow = false

    init(rootView: FlowBarView) {
        hostingController = NSHostingController(rootView: rootView)
        hostingController.sizingOptions = [.intrinsicContentSize]
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                    backing: .buffered, defer: true)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        // M-6: with `.nonactivatingPanel`, clicking a pill control (Open Settings / Download / Copy
        // raw) could otherwise make the panel key and steal key status from the target app — one
        // line of insurance now that more controls land in the pill.
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false

        contentViewController = hostingController
        // `delegate` on `NSWindow` is an unowned/unsafe reference (no retain cycle), and a delegate
        // callback needs no registration bookkeeping to leak or clean up — unlike the
        // `NotificationCenter` observer this replaces (former C8 finding), there is nothing here to
        // remove in a `deinit` in the first place.
        delegate = self
        reflow()
    }

    /// `NSWindowDelegate` — fires reliably for *any* frame change (ours or the content-driven
    /// auto-resize from `NSHostingController.sizingOptions`).
    func windowDidResize(_ notification: Notification) {
        reflow()
    }

    /// Re-derives the frame from the hosting controller's current (auto-updated) size and
    /// re-positions per `present(on:)`; re-anchors (N4) if the key screen has changed.
    private func reflow() {
        guard !suppressReflow, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        if anchoredScreen !== screen {
            anchoredScreen = screen
            leftEdgeX = nil
        }
        present(on: screen)
    }

    /// Anchored per `position` (design 1a default: bottom-center, `midX - width/2`, `minY + 24`) on
    /// first presentation (`leftEdgeX == nil`); afterwards keeps the established left edge fixed as
    /// the pill's width changes, so it only grows right (design 2a). Geometry itself lives in
    /// `FlowBarPositionMath`, which is what's actually unit-tested.
    func present(on screen: NSScreen) {
        let size = frame.size
        let origin = FlowBarPositionMath.origin(size: size, visibleFrame: screen.visibleFrame, position: position, leftEdgeX: leftEdgeX)
        leftEdgeX = origin.x
        guard origin != frame.origin else { return }
        setFrame(NSRect(origin: origin, size: size), display: super.isVisible)
    }

    // MARK: - FlowBarPositioning

    /// Settings › General "Flow Bar position" — re-anchors immediately (same as a screen change)
    /// so a change while the pill is visible takes effect right away, not just on the next show.
    func apply(_ position: FlowBarPosition) {
        guard self.position != position else { return }
        self.position = position
        leftEdgeX = nil
        reflow()
    }

    // MARK: - FlowBarPanelling

    /// Not AppKit's own on-screen/ordering flag (`super.isVisible`, which this deliberately narrows):
    /// also false while a `hide()` fade is in flight, so `FlowBarPresenter` — which gates every
    /// `show()` call on this — reacts immediately rather than waiting for the fade to finish.
    override var isVisible: Bool { super.isVisible && !isHiding }

    func show() {
        generation += 1
        isHiding = false
        // Must come before `reflow()` below (N2): while still `true` from a previous `show()`'s
        // in-flight scale-in, `reflow()` early-returns and the anchor below is computed from a
        // stale (mid-animation, inset) frame instead of this call's real target.
        suppressReflow = false
        leftEdgeX = nil
        anchoredScreen = nil

        // Force any layout the presenter's state-change `Task` may have outrun (N3): the presenter
        // calls `show()` synchronously off a coordinator state change, which can happen before
        // SwiftUI has re-rendered `hostingController.view` for that same new state — anchoring on
        // whatever stale size is currently laid out would centre the pill on the *previous* state's
        // width instead of this one's.
        hostingController.view.layoutSubtreeIfNeeded()
        if hostingController.view.fittingSize != .zero {
            setContentSize(hostingController.view.fittingSize)
        }
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
