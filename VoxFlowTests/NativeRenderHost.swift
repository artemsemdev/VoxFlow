import AppKit
import SwiftUI

/// Keeps SwiftUI controls attached to a real AppKit window while a design fixture is configured
/// and captured. The window stays offscreen so render tests never steal focus from the user.
@MainActor
final class NativeRenderHost {
    private let makeHost: () -> (NSWindow, NSHostingView<AnyView>)
    private lazy var host = makeHost()
    private var window: NSWindow { host.0 }
    private var hostingView: NSHostingView<AnyView> { host.1 }
    private var nativeAlertDidEnd = false

    init(_ content: some View, size: NSSize, dark: Bool = false) {
        makeHost = {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let hostingView = NSHostingView(rootView: AnyView(content
                .frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.controlActiveState, .active)))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = appearance
            hostingView.appearance = appearance
            window.contentView = hostingView
            hostingView.frame = window.contentView!.bounds
            return (window, hostingView)
        }
    }

    func layout() {
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
    }

    func capture(to url: URL) throws {
        layout()
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw RenderError.couldNotCreateBitmap
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderError.couldNotEncodePNG
        }
        try png.write(to: url)
    }

    /// Settle content without ordering a window; only actual sheets need an ordered parent.
    func captureSettled(to url: URL) async throws {
        await onMainRunLoop { self.layout() }
        await nextRunLoopCycle()
        let result: Result<Void, Error> = await onMainRunLoop {
            Result { try self.capture(to: url) }
        }
        await closeSettled()
        try result.get()
    }

    /// Capture the real SwiftUI-presented NSAlert, including its native buttons and text.
    /// Gate on sheet attachment, not a fixed delay; a deadline only bounds fixture failures.
    func captureAlert(to url: URL) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while window.attachedSheet == nil, ContinuousClock.now < deadline {
            await nextRunLoopCycle()
        }
        guard let sheet = window.attachedSheet, let view = sheet.contentView?.superview else {
            throw RenderError.alertDidNotAppear
        }
        // Sheet attachment can be observed inside AppKit's Core Animation commit.
        // Let AppKit finish the current run-loop cycle before capturing the sheet.
        await nextRunLoopCycle()
        let result: Result<Void, Error> = await onMainRunLoop {
            Result {
                sheet.appearance = self.window.appearance
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    throw RenderError.couldNotCreateBitmap
                }
                sheet.effectiveAppearance.performAsCurrentDrawingAppearance {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                }
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw RenderError.couldNotEncodePNG
                }
                try png.write(to: url)
            }
        }
        try result.get()
    }

    /// Use the real native action: clearing a SwiftUI alert binding during layout can start
    /// AppKit's sheet dismissal animation from inside a Core Animation commit.
    func clickAlertButton(titled title: String) async throws {
        let result: Result<Void, Error> = await onMainRunLoop {
            Result {
                guard let view = self.window.attachedSheet?.contentView,
                      let button = self.alertButton(in: view, titled: title) else {
                    throw RenderError.alertButtonNotFound
                }
                button.performClick(nil)
            }
        }
        try result.get()
        try await closeAlert()
    }

    private func alertButton(in view: NSView, titled title: String) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        for child in view.subviews {
            if let button = alertButton(in: child, titled: title) { return button }
        }
        return nil
    }

    /// Let SwiftUI dismiss its own sheet after the fixture clears the alert binding.
    /// Calling endSheet as well races its dismissal and nests a Core Animation transaction.
    func closeAlert() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        repeat { await nextRunLoopCycle() }
        while window.attachedSheet != nil && ContinuousClock.now < deadline
        guard window.attachedSheet == nil else { throw RenderError.alertDidNotDismiss }
        await closeSettled()
    }

    func prepareForAlert() async {
        // Create, lay out and order the sheet parent in a run-loop callback. SwiftUI may drain
        // main-actor jobs during a CA commit; merely resuming an async task cannot avoid that.
        await onMainRunLoop {
            self.layout()
            self.window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            self.window.orderBack(nil)
        }
        await nextRunLoopCycle()
    }

    /// Present an AppKit alert from the production factory using the same native sheet lifecycle.
    func presentAlert(_ alert: NSAlert) async {
        await prepareForAlert()
        nativeAlertDidEnd = false
        await onMainRunLoop {
            alert.beginSheetModal(for: self.window) { _ in self.nativeAlertDidEnd = true }
        }
    }

    func dismissAlert(_ alert: NSAlert, response: NSApplication.ModalResponse = .cancel) async throws {
        await onMainRunLoop {
            self.window.endSheet(alert.window, returnCode: response)
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !nativeAlertDidEnd, ContinuousClock.now < deadline { await nextRunLoopCycle() }
        guard nativeAlertDidEnd else { throw RenderError.alertDidNotDismiss }
        await onMainRunLoop { alert.window.orderOut(nil) }
        try await closeAlert()
    }

    private func onMainRunLoop<Result: Sendable>(_ action: @escaping @MainActor () -> Result) async -> Result {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.default]) {
                // This callback belongs exclusively to the main run loop, on the main thread.
                let result = MainActor.assumeIsolated { action() }
                continuation.resume(returning: result)
            }
        }
    }

    func closeSettled() async {
        await onMainRunLoop { self.window.close() }
        await nextRunLoopCycle()
    }

    private func nextRunLoopCycle() async {
        await withCheckedContinuation { continuation in
            // A before-waiting callback is still part of the outgoing AppKit transaction.
            // Let the run loop wake again before testing sheet attachment or dismissal.
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue,
                                                              false, CFIndex.max) { _, _ in
                continuation.resume()
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    func close() { window.close() }

    private enum RenderError: Error {
        case alertButtonNotFound
        case alertDidNotDismiss
        case alertDidNotAppear
        case couldNotCreateBitmap
        case couldNotEncodePNG
    }
}
