import SwiftUI
import VoxFlowStorage

/// Reserve both labels so feedback never shifts adjacent actions or transcript columns.
struct HistoryCopyButton: View {
    let record: DictationRecord
    let model: HistoryViewModel
    let source: HistoryViewModel.CopySource
    var compact = false

    var body: some View {
        Button { model.copy(record, source: source) } label: {
            ZStack {
                Text(compact ? "Copy" : source.title).hidden()
                Text(HistoryViewModel.copiedTitle).hidden()
                Text(model.copyTitle(for: record, source: source, compact: compact))
            }
            .fixedSize()
        }
        .disabled(!model.canCopy(record, source: source))
        .help(source.title)
        .accessibilityLabel(source.title)
        .accessibilityValue(model.copyTitle(for: record, source: source, compact: compact))
    }
}
