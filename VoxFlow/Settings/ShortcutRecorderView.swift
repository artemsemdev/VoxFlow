import AppKit
import SwiftUI

struct ShortcutRecorderView: View {
    let model: ShortcutRecorderModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 14) {
            Text("Record shortcut for \(model.action?.title ?? "")")
                .font(.system(size: 15, weight: .semibold))
            HStack(spacing: 6) {
                ForEach(Array((model.candidate?.keycaps ?? []).enumerated()), id: \.offset) { _, key in
                    Text(key).font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 8).frame(minWidth: 26, minHeight: 24)
                        .background(.white.opacity(colorScheme == .dark ? 0.12 : 1), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.primary.opacity(0.14)))
                        .shadow(color: .black.opacity(0.16), radius: 0, y: 1.5)
                }
                if model.conflict == nil { Text("+ …").foregroundStyle(.tertiary) }
            }
            .frame(maxWidth: .infinity).frame(height: 64)
            .background(accent.opacity(model.conflict == nil ? 0.06 : 0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(accent, style: StrokeStyle(lineWidth: 1.5, dash: model.conflict == nil ? [5, 3] : [])))

            if model.conflict != nil {
                HStack(alignment: .top, spacing: 10) {
                    Text("!").font(.system(size: 11, weight: .heavy)).foregroundStyle(.white)
                        .frame(width: 18, height: 18).background(accent, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.conflictTitle).fontWeight(.bold)
                        Text(model.instructions).foregroundStyle(.secondary)
                    }.font(.system(size: 12)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
                .background(.white.opacity(colorScheme == .dark ? 0.06 : 1), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.08)))
                // The canvas's 100%-wide content box adds 12 pt padding outside each edge.
                .padding(.horizontal, -12)
            } else {
                Text(model.instructions).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineSpacing(3).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if model.conflict == nil { button(model.defaultTitle, action: model.useDefault) }
                else if case .system = model.conflict { button("Use anyway", action: model.useAnyway) }
                Spacer(minLength: 0)
                button("Cancel", action: model.cancel)
                if model.conflict != nil {
                    button("Choose another", primary: true, action: model.chooseAnother).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20).frame(width: 380)
        .background(colorScheme == .dark ? Color(red: 42 / 255, green: 42 / 255, blue: 46 / 255)
            : Color(red: 236 / 255, green: 236 / 255, blue: 240 / 255))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .fixedSize(horizontal: false, vertical: true)
        .background(ShortcutRecorderInput(model: model).frame(width: 1, height: 1))
    }

    private var accent: Color { model.conflict == nil ? .accentColor : Color(red: 1, green: 159 / 255, blue: 10 / 255) }
    private var controlFill: Color { .white.opacity(colorScheme == .dark ? 0.1 : 1) }

    private func button(_ title: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium)).padding(.horizontal, 14).frame(height: 26)
                .background(primary ? Color.accentColor : controlFill, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(.primary.opacity(primary ? 0 : 0.12)))
                .foregroundStyle(primary ? .white : .primary)
        }.buttonStyle(.plain)
    }
}

/// A sheet-local first responder captures Command combinations before menu key equivalents.
/// It installs no global monitor and cannot observe another application's keyboard events.
struct ShortcutRecorderInput: NSViewRepresentable {
    let model: ShortcutRecorderModel
    func makeNSView(context: Context) -> CaptureView { CaptureView(model: model) }
    func updateNSView(_ nsView: CaptureView, context: Context) { nsView.updateModel(model) }

    final class CaptureView: NSView {
        var model: ShortcutRecorderModel
        private var focusGeneration: UInt64
        func updateModel(_ model: ShortcutRecorderModel) {
            self.model = model
            guard model.isRecording, focusGeneration != model.focusGeneration else { return }
            focusGeneration = model.focusGeneration
            window?.makeFirstResponder(self)
        }
        init(model: ShortcutRecorderModel) {
            self.model = model
            focusGeneration = model.focusGeneration
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.makeFirstResponder(self) }
        override func flagsChanged(with event: NSEvent) { model.modifiersChanged(event.modifierFlags) }
        override func keyDown(with event: NSEvent) {
            model.keyDown(code: event.keyCode, flags: event.modifierFlags,
                          label: event.charactersIgnoringModifiers ?? "", isRepeat: event.isARepeat)
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard model.isRecording, window?.isKeyWindow == true else { return false }
            keyDown(with: event)
            return true
        }
    }
}
