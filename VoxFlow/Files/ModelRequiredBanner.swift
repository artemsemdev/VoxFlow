import SwiftUI

/// Shown atop the Files page while no speech model is installed (`FilesViewModel.needsModel`,
/// design FB-08's Files-page analog). Download routes to Settings › Models (controller ruling 1) —
/// downloading the model itself is Task 4's job, not this view's.
struct ModelRequiredBanner: View {
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(.orange).frame(width: 8, height: 8)
            Text("Speech model not installed")
            Spacer()
            Button("Download", action: onDownload)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
    }
}
