import SwiftUI

/// Empty state (design 2d Files), shown only while the queue is empty — once a file lands,
/// `QueueListView` takes over. The drag-over overlay (design MW-06g) lives at the `FilesPage`
/// level instead of here, since it needs to show over both this view and `QueueListView`.
struct DropZoneView: View {
    @Binding var isFileImporterPresented: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Drop audio or video to transcribe")
                .font(.headline)
            Text("MP3, WAV, M4A, MP4, MOV · any length · processed on this Mac, never uploaded")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Choose Files…") { isFileImporterPresented = true }
                .padding(.top, 8)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 200)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                .foregroundStyle(Color.secondary.opacity(0.35))
        )
    }
}
