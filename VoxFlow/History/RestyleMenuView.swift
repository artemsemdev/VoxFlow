import SwiftUI
import VoxFlowCore
import VoxFlowStorage

/// The "Re-style ▾" popover body (design 2e, MW-02s): one 26 pt row per
/// `HistoryViewModel.restyleOrder` style with a checkmark on the record's current style, a hairline
/// divider, then the footer explaining what happens. Holds no rules of its own — every string and
/// the row order come from `HistoryViewModel`; this view only lays them out and dispatches the tap.
struct RestyleMenuView: View {
    let record: DictationRecord
    let model: HistoryViewModel
    @Environment(\.dismiss) private var dismiss

    private var currentStyle: TextStyle { HistoryViewModel.currentStyle(of: record) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(HistoryViewModel.restyleOrder, id: \.self) { style in
                row(for: style)
            }
            Divider()
            Text(HistoryViewModel.restyleFooter)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(minWidth: 180)
    }

    private func row(for style: TextStyle) -> some View {
        Button {
            Task { await model.restyle(record, to: style) }
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 14))
                    .frame(width: 14)
                    .opacity(style == currentStyle ? 1 : 0)
                Text(style.displayName)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
