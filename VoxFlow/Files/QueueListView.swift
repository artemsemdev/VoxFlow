import SwiftUI

/// The queue list (design MW-06 / 1c Files): a header ("Queue · N files" + status subtitle) over
/// one `QueueRowView` per item, separated by hairlines.
struct QueueListView: View {
    let model: FilesViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                QueueRowView(item: item, model: model)
                if index < model.items.count - 1 { Divider() }
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15))
        )
    }

    private var header: some View {
        HStack {
            Text(model.headerTitle).fontWeight(.semibold)
            Spacer()
            Text(model.headerSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
