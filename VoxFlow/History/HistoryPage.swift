import SwiftUI

/// The History page (design MW-02, MW-02d/e/n, T-01): thin `AppServices` wrapper around
/// `HistoryPageBody`, which holds the actual layout so `HistoryRenderTests` can render exactly the
/// same view instead of a hand-copied approximation.
struct HistoryPage: View {
    @Environment(AppServices.self) private var services
    private var model: HistoryViewModel { services.historyViewModel }

    var body: some View {
        HistoryPageBody(viewModel: model)
            .navigationTitle("History")
            // `.task` re-runs on every navigation back to History — `refresh()` (not `load()`)
            // respects an in-progress search so it doesn't clobber a filtered list with the
            // unfiltered one while the search field still shows a query (M9).
            .task { await model.refresh() }
    }
}

/// The page content below the navigation chrome: search bar, per-dictation rows with inline detail
/// (or an empty state), footer, the delete-undo toast, and the scratchpad sheet.
struct HistoryPageBody: View {
    let viewModel: HistoryViewModel

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Group {
                if let emptyState = viewModel.emptyState {
                    HistoryEmptyView(state: emptyState, model: viewModel)
                } else {
                    list
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // History-off already says so front and centre — a retention/encryption footer under it
            // would read as contradicting itself (M10).
            if viewModel.emptyState != .historyOff {
                Divider()
                Text(viewModel.footerText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay(alignment: .bottom) {
            if viewModel.toastVisible {
                UndoToastView(onUndo: viewModel.undo)
                    .padding(.bottom, 16)
            }
        }
        .sheet(isPresented: scratchpadBinding) {
            ScratchpadSheet(text: scratchpadTextBinding)
        }
    }

    private var scratchpadBinding: Binding<Bool> {
        Binding(get: { viewModel.isScratchpadPresented }, set: { viewModel.isScratchpadPresented = $0 })
    }

    private var scratchpadTextBinding: Binding<String> {
        Binding(get: { viewModel.scratchpadText }, set: { viewModel.scratchpadText = $0 })
    }

    private var queryBinding: Binding<String> {
        Binding(get: { viewModel.query }, set: { viewModel.query = $0 })
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search your dictations", text: queryBinding)
                    .textFieldStyle(.plain)
                if !viewModel.query.isEmpty {
                    Button { viewModel.clearSearch() } label: {
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
            HistorySearchChips()
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private var list: some View {
        ScrollView { HistoryRowList(viewModel: viewModel) }
    }
}

/// The two disabled phase-4 filter chips ("All apps ⇅" / "This week ⇅"). Factored out (not just
/// inlined in `HistoryPageBody`) so `HistoryRenderTests`' preview chrome shares this exact view
/// instead of a hand-copied one (M3) — real `Button`s render fine under `ImageRenderer`; only a live
/// `TextField`/`ScrollView` do not (see that file).
struct HistorySearchChips: View {
    var body: some View {
        HStack(spacing: 8) {
            chip("All apps")
            chip("This week")
        }
    }

    /// A real (disabled) `Button`, not a plain `HStack` with `.disabled(true)` tacked on — the
    /// modifier is a no-op on a non-control view, so an `HStack` would render identically whether or
    /// not it's "disabled" (M7). Matches how "Re-style" and "Search all time" are done.
    private func chip(_ title: String) -> some View {
        Button {} label: {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
        }
        .buttonStyle(.plain)
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.1), in: Capsule())
        .foregroundStyle(.secondary)
        .disabled(true)
    }
}

/// The row list's content: one `HistoryRowView` per record, its `HistoryDetailView` inline when
/// expanded, hairline dividers between. Factored out of `HistoryPageBody.list` (which wraps this in a
/// `ScrollView`) so `HistoryRenderTests` can host the exact same rows/detail wiring without a
/// `ScrollView` (M3) — a live `ScrollView` renders blank under `ImageRenderer` in this environment.
struct HistoryRowList: View {
    let viewModel: HistoryViewModel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(viewModel.records) { record in
                VStack(spacing: 0) {
                    HistoryRowView(record: record, model: viewModel)
                    if viewModel.expandedID == record.id {
                        HistoryDetailView(record: record)
                    }
                    Divider()
                }
            }
        }
        .padding(.horizontal, 20)
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
