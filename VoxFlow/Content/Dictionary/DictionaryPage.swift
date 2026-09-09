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

/// "Word · Sounds like · Type · Uses" (design MW-03) — matches `DictionaryRowView`'s column widths.
struct DictionaryColumnHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Word").frame(maxWidth: .infinity, alignment: .leading)
            Text("Sounds like").frame(maxWidth: .infinity, alignment: .leading)
            Text("Type").frame(width: 90, alignment: .leading)
            Text("Uses").frame(width: 50, alignment: .trailing)
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
            typePill.frame(width: 90, alignment: .leading)
            Group {
                if isHovering { actions } else { Text("\(entry.uses)").foregroundStyle(.secondary) }
            }
            .frame(width: 90, alignment: .trailing)
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
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(isDenied ? Color.orange : .secondary)
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

    private var subtitle: String {
        switch viewModel.contacts {
        case .off: "Reads first and last names locally. Nothing is uploaded."
        case .importing: "Importing \(placeholderCount) names… nothing is uploaded"
        case .done(let count): "\(count) names added · updates when Contacts change"
        case .denied: "Contacts access was denied. Allow it in System Settings → Privacy & Security → Contacts."
        }
    }

    /// `.importing` doesn't know the final count yet — the design's sample copy ("Importing 312
    /// names…") shows a concrete number, so this reuses the last known `.done` count, falling back to
    /// the entry count already loaded (both are the best guess available mid-import; the count firms
    /// up the moment `.done` replaces this state).
    private var placeholderCount: Int {
        viewModel.entries.filter { $0.source == "contacts" }.count
    }

    private var toggleBinding: Binding<Bool> {
        Binding(get: { viewModel.stylingSettings.learnFromContacts },
               set: { newValue in Task { await viewModel.setLearnFromContacts(newValue) } })
    }
}
