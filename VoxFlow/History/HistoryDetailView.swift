import SwiftUI
import VoxFlowStorage

/// The inline expanded detail (design MW-02d): raw vs. inserted text side by side. The design's
/// filler/confidence chips are phase 5 (LLM cleanup) — omitted here per the task brief.
struct HistoryDetailView: View {
    let record: DictationRecord

    private var insertedHeader: String {
        guard let style = record.style, !style.isEmpty else { return "INSERTED" }
        return "INSERTED · \(style.uppercased())"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 24) {
                column(title: "WHAT YOU SAID", text: displayRawText)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(insertedHeader)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Edit") {}
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.tint)
                            .disabled(true)
                    }
                    Text(displayText)
                        .font(.callout)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Audio was not saved.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var displayRawText: String { record.isUnreadable ? HistoryViewModel.unreadableMessage : record.rawText }
    private var displayText: String { record.isUnreadable ? HistoryViewModel.unreadableMessage : record.text }

    private func column(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
