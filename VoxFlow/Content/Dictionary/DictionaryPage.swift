import SwiftUI
import VoxFlowStorage

/// The Dictionary page (design MW-03, 03a, 03v, 03c, 03e): thin `AppServices` wrapper around
/// `DictionaryPageBody`, which holds the actual layout so `DictionaryRenderTests` can render exactly
/// the same view instead of a hand-copied approximation (same split `HistoryPage`/`HistoryPageBody`
/// pattern uses).
struct DictionaryPage: View {
    @Environment(AppServices.self) private var services
    private var model: DictionaryViewModel { services.dictionaryViewModel }

    var body: some View {
        DictionaryPageBody(viewModel: model)
            .navigationTitle("Dictionary")
            .task { await model.load() }
    }
}

/// The page content below the navigation chrome: intro + "+ Add word", the word list or empty state,
/// the Contacts toggle row, and the "Add word" sheet.
struct DictionaryPageBody: View {
    let viewModel: DictionaryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if viewModel.isEmpty {
                DictionaryEmptyView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView { DictionaryList(viewModel: viewModel) }
            }
            DictionaryContactsRow(viewModel: viewModel)
        }
        .padding(20)
        .sheet(isPresented: sheetBinding) {
            AddWordSheet(viewModel: viewModel)
        }
    }

    private var header: some View {
        HStack(alignment: .lastTextBaseline, spacing: 16) {
            Text("Names and terms VoxFlow should always get right. Add how they sound if the spelling isn't obvious.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520, alignment: .leading)
            Spacer(minLength: 0)
            Button("+ Add word") { viewModel.presentAdd() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var sheetBinding: Binding<Bool> {
        Binding(get: { viewModel.sheet != nil }, set: { if !$0 { viewModel.cancelSheet() } })
    }

}

/// The word list's content — column header + one `DictionaryRowView` per entry. Factored out of
/// `DictionaryPageBody` (which wraps this in a `ScrollView`) so `DictionaryRenderTests` can render
/// the exact same rows without a live `ScrollView` (blank under `ImageRenderer`, same issue
/// `HistoryRowList`'s doc comment describes).
struct DictionaryList: View {
    let viewModel: DictionaryViewModel

    var body: some View {
        VStack(spacing: 0) {
            DictionaryColumnHeader()
            ForEach(viewModel.entries) { entry in
                DictionaryRowView(entry: entry, viewModel: viewModel)
                Divider()
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.secondary.opacity(0.12)))
    }
}

/// Column widths shared by `DictionaryColumnHeader` and `DictionaryRowView` (F1 fix) — the header
/// previously reserved `Type 90 / Uses 50` while the row reserved `pill 90 / value 90`, so the "Type"
/// and "Uses" labels drifted from the columns they were meant to sit above. One shared source of
/// truth for the two fixed-width trailing columns; "Word"/"Sounds like" both stay `maxWidth: .infinity`
/// in each view and so need no shared constant.
private enum DictionaryColumn {
    static let type: CGFloat = 90
    static let trailing: CGFloat = 90
}

/// "Word · Sounds like · Type · Uses" (design MW-03) — matches `DictionaryRowView`'s column widths
/// via `DictionaryColumn`.
struct DictionaryColumnHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Word").frame(maxWidth: .infinity, alignment: .leading)
            Text("Sounds like").frame(maxWidth: .infinity, alignment: .leading)
            Text("Type").frame(width: DictionaryColumn.type, alignment: .leading)
            Text("Uses").frame(width: DictionaryColumn.trailing, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// One dictionary row (design MW-03): word, italic "sounds like" hint, a type pill, uses count, and
/// hover actions (Edit/Delete) — same hover-reveal pattern as `HistoryRowView`.
struct DictionaryRowView: View {
    let entry: DictionaryEntry
    let viewModel: DictionaryViewModel
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Text(entry.word).fontWeight(.medium).frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.soundsLike?.isEmpty == false ? entry.soundsLike! : "—")
                .italic()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            typePill.frame(width: DictionaryColumn.type, alignment: .leading)
            Group {
                if isHovering { actions } else { Text("\(entry.uses)").foregroundStyle(.secondary) }
            }
            .frame(width: DictionaryColumn.trailing, alignment: .trailing)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private var typePill: some View {
        Text(entry.type.displayName)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button("Edit") { viewModel.editExisting(entry) }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            Button("Delete") { viewModel.delete(entry) }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
        }
        .font(.caption)
    }
}

/// "Your dictionary is empty" (design 2d MW-03e): one icon, one line of body copy, two actions.
struct DictionaryEmptyView: View {
    let viewModel: DictionaryViewModel

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.secondary.opacity(0.1)).frame(width: 56, height: 56)
                Image(systemName: "character.book.closed").font(.system(size: 22)).foregroundStyle(.secondary)
            }
            Text("Your dictionary is empty").font(.headline)
            Text("Add names, products and jargon VoxFlow keeps mishearing. Or let it learn names from Contacts — locally.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack(spacing: 8) {
                Button("Add word") { viewModel.presentAdd() }
                    .buttonStyle(.borderedProminent)
                Button("Import from Contacts") { Task { await viewModel.setLearnFromContacts(true) } }
                    .buttonStyle(.bordered)
            }
        }
    }
}

/// The bottom "Learn names from Contacts" toggle row (design MW-03 / MW-03c): its subtitle and
/// background swap for `.importing`/`.done`/`.denied`; `.denied` shows the amber warning and "Open
/// System Settings" — the toggle itself always reflects `stylingSettings.learnFromContacts`, which
/// `setLearnFromContacts` snaps back to false on denial.
struct DictionaryContactsRow: View {
    let viewModel: DictionaryViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Learn names from Contacts").fontWeight(.medium)
                subtitleView
            }
            Spacer(minLength: 12)
            if isDenied {
                Button("Open System Settings") { viewModel.openContactsSettings() }
                    .buttonStyle(.bordered)
            }
            Toggle("", isOn: toggleBinding)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(isDenied ? Color.orange.opacity(0.12) : Color(nsColor: .controlBackgroundColor),
                   in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isDenied ? Color.orange.opacity(0.3) : Color.secondary.opacity(0.12)))
    }

    private var isDenied: Bool { viewModel.contacts == .denied }

    /// F2 fix: `.importing`'s count now comes straight from `ContactsState.importing(count:)` — set
    /// by `runContactsImport` to the real fetched count before the insert loop runs, not derived from
    /// `entries` (which stayed 0 until rows actually landed, showing "Importing 0 names…" the whole
    /// time). `nil` (still fetching) shows the spinner with no number yet, matching the canvas's
    /// loading glyph before the count is known.
    @ViewBuilder
    private var subtitleView: some View {
        switch viewModel.contacts {
        case .off:
            Text("Reads first and last names locally. Nothing is uploaded.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .importing(let count):
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text(count.map { "Importing \($0) names… nothing is uploaded" } ?? "Importing names… nothing is uploaded")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .done(let count):
            Text("\(count) names added · updates when Contacts change")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .denied:
            Text("Contacts access was denied. Allow it in System Settings → Privacy & Security → Contacts.")
                .font(.caption)
                .foregroundStyle(Color.orange)
        }
    }

    private var toggleBinding: Binding<Bool> {
        Binding(get: { viewModel.stylingSettings.learnFromContacts },
               set: { newValue in Task { await viewModel.setLearnFromContacts(newValue) } })
    }
}
