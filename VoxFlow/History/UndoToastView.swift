import SwiftUI

/// The delete-undo toast (design T-01): dark pill, "Dictation deleted" + "Undo ⌘Z", up while
/// `HistoryViewModel.toastVisible` (6 s, or until undone).
struct UndoToastView: View {
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Text("Dictation deleted")
                .foregroundStyle(.white)
            Button(action: onUndo) {
                Text("Undo ⌘Z").fontWeight(.semibold)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .keyboardShortcut("z", modifiers: .command)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.85), in: Capsule())
        .shadow(radius: 8, y: 2)
    }
}
