import SwiftUI
import VoxFlowStorage

/// The History page (design MW-02, MW-02d/e/n, T-01): thin `AppServices` wrapper around
/// `HistoryPageBody`, which holds the actual layout so `HistoryRenderTests` can render exactly the
/// same view instead of a hand-copied approximation.
struct HistoryPage: View {
    @Environment(AppServices.self) private var services
    private var model: HistoryViewModel { services.historyViewModel }

    var body: some View {
        HistoryPageBody(viewModel: model, ephemeralScope: services.ephemeralScope) { word in
            Task { await services.dictionaryViewModel.addFromHistory(word) }
        }
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
    let ephemeralScope: EphemeralScope
    var addToDictionary: @MainActor (String) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            searchBar.disabled(viewModel.editingID != nil)
            Group {
                if let emptyState = viewModel.emptyState {
                    HistoryEmptyView(state: emptyState, model: viewModel)
                } else {
                    list
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // History-off already says so front and centre, and an unavailable store has nothing a
            // retention/encryption footer could usefully add — either would read as contradicting the
            // empty state above it (M10, extended to I-4's `.unavailable`).
            if !hidesFooter {
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
            ScratchpadSheet(text: scratchpadTextBinding, ephemeralScope: ephemeralScope)
        }
    }

    private var hidesFooter: Bool {
        switch viewModel.emptyState {
        case .historyOff, .unavailable: true
        case .noDictations, .noResults, nil: false
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

            HistorySearchChips(viewModel: viewModel)
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private var list: some View {
        ScrollView { HistoryRowList(viewModel: viewModel, addToDictionary: addToDictionary) }
    }
}

/// MW-02 filter chips; the view model owns the choices and filtering rules.
struct HistorySearchChips: View {
    let viewModel: HistoryViewModel
    @State private var appsPresented = false
    @State private var datesPresented = false

    var body: some View {
        HStack(spacing: 8) {
            chip(viewModel.selectedApp ?? "All apps") { appsPresented = true }
                .accessibilityLabel("Filter by app")
                .accessibilityValue(viewModel.selectedApp ?? "All apps")
                .popover(isPresented: $appsPresented, arrowEdge: .bottom) {
                    ScrollView {
                        HistoryFilterOptions(choices: viewModel.availableApps, selected: viewModel.selectedApp,
                                             allLabel: "All apps") {
                            viewModel.selectedApp = $0
                            appsPresented = false
                        }
                    }
                    .frame(width: 200, height: min(CGFloat(viewModel.availableApps.count + 1) * 28 + 20, 280))
                }
            chip(viewModel.dateRange.rawValue) { datesPresented = true }
                .accessibilityLabel("Filter by date")
                .accessibilityValue(viewModel.dateRange.rawValue)
                .popover(isPresented: $datesPresented, arrowEdge: .bottom) {
                    HistoryFilterOptions(choices: HistoryViewModel.DateRange.allCases.map(\.rawValue),
                                         selected: viewModel.dateRange.rawValue) { value in
                        if let value, let range = HistoryViewModel.DateRange(rawValue: value) {
                            viewModel.dateRange = range
                        }
                        datesPresented = false
                    }
                }
        }
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 4))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .font(.callout)
    }
}

/// Shared with render tests so the open menu uses the same rows as the live popover.
struct HistoryFilterOptions: View {
    let choices: [String]
    let selected: String?
    var allLabel: String?
    let select: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let allLabel {
                option(allLabel, value: nil)
                Divider()
            }
            ForEach(choices, id: \.self) { option($0, value: $0) }
        }
        .padding(6)
        .frame(width: 200)
    }

    private func option(_ title: String, value: String?) -> some View {
        Button { select(value) } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark").opacity(selected == value ? 1 : 0).frame(width: 16)
                Text(title)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(minHeight: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected == value ? .isSelected : [])
    }
}

/// The row list's content: one `HistoryRowView` per record, its `HistoryDetailView` inline when
/// expanded, with separators between collapsed rows. Factored out of `HistoryPageBody.list` (which wraps this in a
/// `ScrollView`) so `HistoryRenderTests` can host the exact same rows/detail wiring without a
/// `ScrollView` (M3) — a live `ScrollView` renders blank under `ImageRenderer` in this environment.
struct HistoryRowList: View {
    let viewModel: HistoryViewModel
    var addToDictionary: @MainActor (String) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(viewModel.records) { record in
                if viewModel.expandedID == record.id {
                    HistoryCardView(record: record, model: viewModel, addToDictionary: addToDictionary)
                } else {
                    HistoryRowView(record: record, model: viewModel)
                    Divider()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 1)
    }
}

/// One joined card, shared by the production list and native editor render fixtures.
struct HistoryCardView: View {
    let record: DictationRecord
    let model: HistoryViewModel
    var addToDictionary: @MainActor (String) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let colors = HistoryCardColors(scheme: colorScheme)
        VStack(spacing: 0) {
            HistoryRowView(record: record, model: model)
            if model.expandedID == record.id {
                HistoryDetailView(record: record, model: model, addToDictionary: addToDictionary)
            }
        }
        .background(colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(colors.border))
    }
}

/// "Try it in a scratchpad" (design 2d): a small sheet to say something into without leaving a real
/// history entry — entering/leaving `ephemeralScope` on appear/disappear is what keeps a capture
/// started while this is up out of real History (I-1/I-2/I-3), the same pattern onboarding's Try It
/// step uses (`OnboardingViewModel.beginTryIt()`/`endTryIt()`).
private struct ScratchpadSheet: View {
    @Binding var text: String
    let ephemeralScope: EphemeralScope
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
        .onAppear { ephemeralScope.enter() }
        .onDisappear { ephemeralScope.leave() }
    }
}
