import AppKit
import SwiftUI
import Testing
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("Main window opacity", .timeLimit(.minutes(1)))
@MainActor
struct WindowOpacityBridgeTests {
    @Test("saved opacity applies on attachment and recreation, updates live, and leaves panels alone")
    func attachmentAndLiveUpdates() async throws {
        let store = InMemoryKeyValueStore()
        let settings = GeneralSettings(store: store)
        settings.windowOpacity = 0.35
        var window: NSWindow?
        var panel: NSPanel?
        var host: NSHostingView<Content>?
        await onRunLoop {
            window = makeWindow()
            panel = NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
            panel?.isReleasedWhenClosed = false
            host = NSHostingView(rootView: Content(settings: settings))
            window?.contentView = host
        }
        do {
            try #require(await reaches(0.35, window: { window }))
            settings.windowOpacity = 0.6
            try #require(await reaches(0.6, window: { window }))
            let untouched = await onRunLoop { panel?.alphaValue == 1 }
            #expect(untouched, "A Flow Bar or popup must not inherit the main window's opacity")
            await onRunLoop {
                window?.contentView = nil
                window?.close()
                window = makeWindow()
                window?.contentView = host
            }
            try #require(await reaches(0.6, window: { window }))
            await onRunLoop {
                window?.contentView = nil
                window?.close()
                window = makeWindow()
                host = NSHostingView(rootView: Content(settings: GeneralSettings(store: store)))
                window?.contentView = host
            }
            try #require(await reaches(0.6, window: { window }))
        } catch {
            await onRunLoop { window?.contentView = nil; window?.close(); panel?.close(); host = nil }
            throw error
        }
        await onRunLoop { window?.contentView = nil; window?.close(); panel?.close(); host = nil }
    }

    private struct Content: View {
        let settings: GeneralSettings
        var body: some View {
            Color.clear.frame(width: 100, height: 100)
                .background(WindowOpacityBridge(value: settings.windowOpacity))
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func reaches(_ opacity: Double, window: @escaping @MainActor () -> NSWindow?) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        repeat {
            if await onRunLoop({
                window()?.contentView?.layoutSubtreeIfNeeded()
                return window()?.alphaValue == CGFloat(opacity)
            }) { return true }
        } while ContinuousClock.now < deadline
        return false
    }

    private func onRunLoop<T: Sendable>(_ action: @escaping @MainActor () -> T) async -> T {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.default]) {
                // RunLoop.main invokes this callback on the main thread, satisfying MainActor isolation.
                continuation.resume(returning: MainActor.assumeIsolated { action() })
            }
        }
    }
}
