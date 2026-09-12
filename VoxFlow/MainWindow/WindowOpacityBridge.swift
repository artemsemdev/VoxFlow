import SwiftUI

/// Installed only in MainWindow: a setting change affects its containing window, never panels.
struct WindowOpacityBridge: NSViewRepresentable {
    let value: Double

    func makeNSView(context: Context) -> OpacityView { OpacityView() }

    func updateNSView(_ view: OpacityView, context: Context) { view.value = value }

    final class OpacityView: NSView {
        var value: Double = 1 { didSet { apply() } }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        private func apply() { window?.alphaValue = CGFloat(value) }
    }
}
