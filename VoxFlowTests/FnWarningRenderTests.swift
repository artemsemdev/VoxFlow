import AppKit
import SwiftUI
import Testing
@testable import VoxFlow

@Suite("Fn system action warning") @MainActor
struct FnWarningTests {
    @Test("refresh can reveal a warning after the hidden state")
    func refresh() {
        let state = FnSystemActionWarningState(action: .doNothing, currentAction: { .changeInputSource })
        #expect(state.message == nil)
        state.refresh()
        #expect(state.action == .changeInputSource)
        #expect(state.message != nil)
    }

    @Test("known and unknown actions use accurate guidance")
    func guidance() {
        #expect(FnSystemActionWarningState(action: .doNothing).message == nil)
        #expect(FnSystemActionWarningState(action: .emoji).message?.contains("Show Emoji & Symbols") == true)
        let unknown = FnSystemActionWarningState(action: .unknown).message
        #expect(unknown?.contains("Check the fn key action") == true)
        #expect(unknown?.contains("currently") == false)
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_RENDER"] != nil)) @MainActor
struct FnWarningRenderTests {
    @Test("renders the reusable banner in light and dark")
    func nativeRenders() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".superpowers/design/renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for dark in [false, true] {
            for (name, action) in [("configured", FnSystemAction.changeInputSource), ("unknown", .unknown)] {
                let state = FnSystemActionWarningState(action: action, currentAction: { action })
                try render(FnSystemActionWarning(state: state, openKeyboard: {}), width: 560,
                           name: "Fn-warning-\(name)-\(dark ? "dark" : "light")", dark: dark, directory: directory)
            }
        }
    }

    private func render(_ view: some View, width: CGFloat, name: String, dark: Bool, directory: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: width).padding(20)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light))
        let size = host.fittingSize
        #expect(size.width > 0 && size.height > 0)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.appearance = window.appearance
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("\(name).png"))
    }
}
