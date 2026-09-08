import SwiftUI

/// Empty state (design 2d Files) and drag-over overlay (design MW-06g), shown only while the queue
/// is empty — once a file lands, `QueueListView` takes over and the drop target stays live on the
/// whole page (see `FilesPage`).
///
/// The drag-over copy in design MW-06g is "Release to add N files" + a duration line. Neither is
/// buildable from the mandated `.dropDestination(for: URL.self)`/`isTargeted: (Bool) -> Void` API
/// (controller ruling 3): that signature only reports whether *something* is hovering, not what —
/// the item count and durations are known only once the drop's `action` closure actually runs. So
/// this shows a generic "Release to add files" while dragging; the real count/duration appear a
/// moment later in the queue header once `addFiles` lands the rows.
struct DropZoneView: View {
    let model: FilesViewModel
    @Binding var isFileImporterPresented: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(model.isDragOver ? Color.accentColor : .secondary)

            if model.isDragOver {
                Text("Release to add files")
                    .font(.headline)
                Text("Processed on this Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Drop audio or video to transcribe")
                    .font(.headline)
                Text("MP3, WAV, M4A, MP4, MOV · any length · processed on this Mac, never uploaded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Choose Files…") { isFileImporterPresented = true }
                    .padding(.top, 8)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 200)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(model.isDragOver ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                .foregroundStyle(model.isDragOver ? Color.accentColor : Color.secondary.opacity(0.35))
        )
    }
}
