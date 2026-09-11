import AppKit
import SwiftUI
import Testing
import VoxFlowTestSupport
@testable import VoxFlow

@Suite(.enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_RENDER"] != nil)) @MainActor
struct ShortcutRecorderRenderTests {
    @Test("renders native Hotkeys and both recorder states in light and dark")
    func nativeRenders() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".superpowers/design/renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            let settings = DictationSettings(store: InMemoryKeyValueStore())
            let model = ShortcutRecorderModel(settings: settings, systemConflict: { _ in "Spotlight" })
            try render(HotkeysSettingsBody(settings: settings), size: NSSize(width: 640, height: 350),
                       name: "Hotkeys", dark: dark, directory: directory)
            let warning = FnSystemActionWarningState(action: .changeInputSource, currentAction: { .changeInputSource })
            try render(HotkeysSettingsBody(settings: settings, fnWarning: warning), size: NSSize(width: 640, height: 0),
                       name: "Hotkeys-fn-warning", dark: dark, directory: directory)
            model.begin(.pushToTalk)
            model.modifiersChanged([.control, .option])
            try render(ShortcutRecorderView(model: model), size: NSSize(width: 380, height: 0),
                       name: "Shortcut-record", dark: dark, directory: directory)
            model.begin(.handsFree)
            model.keyDown(code: 49, flags: .option, label: " ")
            try render(ShortcutRecorderView(model: model), size: NSSize(width: 380, height: 0),
                       name: "Shortcut-conflict", dark: dark, directory: directory)
        }
    }

    private func render(_ view: some View, size: NSSize, name: String, dark: Bool, directory: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height == 0 ? nil : size.height)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light))
        let fittedSize = size.height == 0 ? host.fittingSize : size
        #expect(fittedSize.width > 0 && fittedSize.height > 0)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: fittedSize), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.appearance = window.appearance
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    }
}
