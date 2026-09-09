import SwiftUI

/// The History page (design MW-02, MW-02d/e/n, T-01): search, per-dictation rows with inline
/// detail, delete-with-undo, and the History-off / no-dictations / no-results empty states.
struct HistoryPage: View {
    @Environment(AppServices.self) private var services
    private var model: HistoryViewModel { services.historyViewModel }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Group {
                if let emptyState = model.emptyState {
                    HistoryEmptyView(state: emptyState, model: model)
                } else {
                    list
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            Text(model.footerText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("History")
        .task { await model.load() }
        .overlay(alignment: .bottom) {
            if model.toastVisible {
                UndoToastView(onUndo: model.undo)
                    .padding(.bottom, 16)
            }
        }
        .sheet(isPresented: scratchpadBinding) {
            ScratchpadSheet(text: scratchpadTextBinding)
        }
    }

    private var scratchpadBinding: Binding<Bool> {
        Binding(get: { model.isScratchpadPresented }, set: { model.isScratchpadPresented = $0 })
    }

    private var scratchpadTextBinding: Binding<String> {
        Binding(get: { model.scratchpadText }, set: { model.scratchpadText = $0 })
    }

    private var queryBinding: Binding<String> {
        Binding(get: { model.query }, set: { model.query = $0 })
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search your dictations", text: queryBinding)
                    .textFieldStyle(.plain)
                if !model.query.isEmpty {
                    Button { model.clearSearch() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.secondary.opacity(0.25)))

            // Phase 4 filters — rendered so the layout matches the design, disabled until then.
            disabledChip("All apps")
            disabledChip("This week")
        }
        .padding(20)
    }

    private func disabledChip(_ title: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Image(systemName: "chevron.up.chevron.down").font(.caption2)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.1), in: Capsule())
        .foregroundStyle(.secondary)
        .disabled(true)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(model.records) { record in
                    VStack(spacing: 0) {
                        HistoryRowView(record: record, model: model)
                        if model.expandedID == record.id {
                            HistoryDetailView(record: record)
                        }
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }
}

/// "Try it in a scratchpad" (design 2d): a small sheet to say something into without leaving a real
/// history entry — `HistoryViewModel` suppresses the next save for as long as this is up (the same
/// pattern onboarding's Try It step uses).
private struct ScratchpadSheet: View {
    @Binding var text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scratchpad").font(.headline)
            Text("Hold fn and say anything.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .frame(minWidth: 360, minHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.secondary.opacity(0.2)))
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }
}
