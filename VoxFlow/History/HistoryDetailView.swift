import SwiftUI
import VoxFlowStorage

/// The inline expanded detail (design MW-02d): raw vs. inserted text side by side. The design's
/// filler/confidence chips are phase 5 (LLM cleanup) — omitted here per the task brief.
struct HistoryDetailView: View {
    let record: DictationRecord
    @Bindable var model: HistoryViewModel
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 24) {
                column(title: "WHAT YOU SAID", text: HistoryViewModel.displayRawText(for: record))
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(HistoryViewModel.detailHeader(for: record))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        editActions
                    }
                    if model.editingID == record.id {
                        TextEditor(text: $model.editedText)
                            .font(.callout)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .frame(height: 100)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.5)))
                            .focused($editorFocused)
                            .onAppear { editorFocused = true }
                            .onExitCommand { model.cancelEdit() }
                            .disabled(model.isSavingEdit)
                            .accessibilityLabel("Edit inserted text")
                        if let error = model.editError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    } else {
                        Text(HistoryViewModel.displayText(for: record)).font(.callout)
                    }
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

    private var editActions: some View {
        HStack(spacing: 10) {
            if model.editingID == record.id {
                Button("Cancel") { model.cancelEdit() }
                    .disabled(model.isSavingEdit)
                Button(model.editSaveTitle) { Task { await model.saveEdit() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canSaveEdit)
            } else {
                Button("Edit") { model.beginEditing(record) }
                    .disabled(!model.canEdit(record))
            }
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.tint)
    }

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
