import SwiftUI

/// The live MW-06g overlay used while files are held over the Files page.
struct FilesDragOverOverlay: View {
    let dragCount: Int

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 11))
            Text("Release to add \(dragCount) \(dragCount == 1 ? "file" : "files")").font(.headline)
            Text("processed on this Mac").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.accentColor.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
        )
        .padding(8)
        .allowsHitTesting(false)
    }

}

/// Shared production alert presentation; native fixtures exercise the same buttons and copy.
struct FilesAlerts: ViewModifier {
    let model: FilesViewModel

    func body(content: Content) -> some View {
        content.alert(alertTitle, isPresented: alertIsPresented, presenting: model.confirmation) { confirmation in
            alertButtons(confirmation)
        } message: { confirmation in
            Text(alertMessage(confirmation))
        }
    }

    // MARK: Alerts (design MW-06c stop confirmation, 3e long-audio confirmation)

    private var alertIsPresented: Binding<Bool> {
        Binding(get: { model.confirmation != nil }, set: { isPresented in
            if !isPresented { model.cancelConfirmation() }
        })
    }

    private var alertTitle: String {
        switch model.confirmation {
        case .stop(let item, _): FilesViewModel.stopAlertTitle(for: item)
        case .longAudio(_, let hours): FilesViewModel.longAudioAlertTitle(hours: hours)
        case nil: ""
        }
    }

    private func alertMessage(_ confirmation: FilesViewModel.Confirmation) -> String {
        switch confirmation {
        case .stop(_, let progress): FilesViewModel.stopAlertMessage(progress: progress)
        case .longAudio(_, let hours): FilesViewModel.longAudioAlertMessage(hours: hours)
        }
    }

    @ViewBuilder
    private func alertButtons(_ confirmation: FilesViewModel.Confirmation) -> some View {
        switch confirmation {
        case .stop:
            Button("Keep going", role: .cancel) { model.cancelConfirmation() }
            Button("Stop", role: .destructive) { Task { await model.confirmStop() } }
        case .longAudio:
            Button("Cancel", role: .cancel) { model.cancelConfirmation() }
            Button("Transcribe") { Task { await model.confirmLongAudio() } }
        }
    }
}
