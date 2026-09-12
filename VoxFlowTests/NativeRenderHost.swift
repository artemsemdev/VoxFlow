import AppKit
import SwiftUI

/// Keeps SwiftUI controls attached to a real AppKit window while a design fixture is configured
/// and captured. The window stays offscreen so render tests never steal focus from the user.
@MainActor
final class NativeRenderHost {
    private let window: NSWindow
    private let hostingView: NSHostingView<AnyView>

    init(_ content: some View, size: NSSize, dark: Bool = false) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hostingView = NSHostingView(rootView: AnyView(content
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)))
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        hostingView.appearance = appearance
        window.contentView = hostingView
        hostingView.frame = window.contentView!.bounds
        layout()
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

    func close() { window.close() }

    private enum RenderError: Error {
        case couldNotCreateBitmap
        case couldNotEncodePNG
    }
}
