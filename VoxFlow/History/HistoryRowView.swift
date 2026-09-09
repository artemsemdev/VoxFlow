import SwiftUI
import VoxFlowStorage

/// One History row (design MW-02 / 2e): coloured app-initial tile, single-line text, meta line, and
/// hover/selection actions (Copy, the phase-5 "Re-style ▾", Delete). Tapping toggles the inline
/// detail (design MW-02d).
struct HistoryRowView: View {
    let record: DictationRecord
    let model: HistoryViewModel
    @State private var isHovering = false

    private var isExpanded: Bool { model.expandedID == record.id }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            tile
            VStack(alignment: .leading, spacing: 4) {
                Text(HistoryViewModel.displayText(for: record))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(record.isUnreadable ? .secondary : .primary)
                Text(HistoryViewModel.metaLine(for: record))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if isHovering || isExpanded {
                actions
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .background(isExpanded ? Color.accentColor.opacity(0.06) : Color.clear)
        .onTapGesture { model.toggleExpanded(id: record.id) }
        .onHover { isHovering = $0 }
    }

    private var tile: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(HistoryViewModel.color(for: record.appName))
            .frame(width: 32, height: 32)
            .overlay(
                Text(HistoryViewModel.initial(for: record.appName))
                    .font(.headline)
                    .foregroundStyle(.white)
            )
    }

    private var actions: some View {
        HStack(spacing: 14) {
            Button("Copy") { model.copy(record) }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            // Re-style rewrites locally via the phase-5 on-device LLM cleanup — not built yet.
            Button {} label: {
                HStack(spacing: 2) {
                    Text("Re-style")
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(true)
            Button("Delete") { model.delete(record) }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
        }
        .font(.callout)
    }
}
