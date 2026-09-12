import AppKit
import SwiftUI
import Testing
import VoxFlowModels
import VoxFlowTestSupport
@testable import VoxFlow

@Suite(.enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_RENDER"] == "1"))
@MainActor
struct SidebarRenderTests {
    @Test("native sidebar footer wraps exact measured totals at the minimum sidebar width",
          arguments: [Int64(0), 1234, Int64.max], [false, true])
    func footer(bytes: Int64, dark: Bool) throws {
        let counter = ModelRequestByteCounter(store: InMemoryKeyValueStore(), now: Date(timeIntervalSince1970: 100))
        counter.record(headerBytes: bytes, bodyBytes: 0)
        let content = SidebarFooter(requestBytes: counter).frame(width: 200)
            .fixedSize(horizontal: false, vertical: true)
            .background(dark ? Color(white: 0.12) : Color(white: 0.97))
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.appearance = window.appearance
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".superpowers/design/renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("Sidebar-\(bytes)-\(dark ? "dark" : "light").png"))
    }
}
