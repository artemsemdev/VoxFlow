import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class FnSystemActionWarningState {
    private(set) var action: FnSystemAction
    private let currentAction: @MainActor () -> FnSystemAction

    init(action: FnSystemAction, currentAction: @escaping @MainActor () -> FnSystemAction = { FnSystemAction.current() }) {
        self.action = action
        self.currentAction = currentAction
    }

    convenience init(currentAction: @escaping @MainActor () -> FnSystemAction = { FnSystemAction.current() }) {
        self.init(action: currentAction(), currentAction: currentAction)
    }

    var message: String? {
        switch action {
        case .doNothing:
            nil
        case .unknown:
            "Check the fn key action in Keyboard settings. Choose “Do Nothing” for “Press fn key to” so VoxFlow can use fn reliably."
        case .changeInputSource, .emoji, .startDictation:
            "macOS assigns fn to “\(action.conflictName ?? "another action")”. Choose “Do Nothing” for “Press fn key to” in Keyboard settings so VoxFlow can use fn reliably."
        }
    }

    func refresh() { action = currentAction() }
}

struct FnSystemActionWarning: View {
    let state: FnSystemActionWarningState
    var openKeyboard: @MainActor () -> Void = Self.openKeyboardSettings

    var body: some View {
        Group {
            if let message = state.message {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: state.action == .unknown ? "info.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(tint)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(message).font(.callout)
                        Button("Open Keyboard settings", action: openKeyboard)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(tint.opacity(0.35)))
            }
        }
        .onAppear { state.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.refresh()
        }
    }

    private var tint: Color { state.action == .unknown ? .blue : .orange }

    static func openKeyboardSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}
