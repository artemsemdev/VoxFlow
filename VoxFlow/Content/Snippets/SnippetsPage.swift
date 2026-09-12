import SwiftUI
import VoxFlowStorage

/// The Snippets page (design MW-04, 04a, 04v, 04e): thin `AppServices` wrapper around
/// `SnippetsPageBody`, which holds the actual layout so `SnippetsRenderTests` can render exactly the
/// same view instead of a hand-copied approximation (same split `DictionaryPage`/`DictionaryPageBody`
/// pattern uses).
struct SnippetsPage: View {
    @Environment(AppServices.self) private var services
    private var model: SnippetsViewModel { services.snippetsViewModel }

    var body: some View {
        SnippetsPageBody(viewModel: model)
            .navigationTitle("Snippets")
            .task { await model.load() }
    }
}

/// The page content below the navigation chrome: intro + "+ New snippet", the card grid or empty
/// state, the "Say 'snippet' before the trigger" toggle row, and the "New snippet" sheet.
struct SnippetsPageBody: View {
    let viewModel: SnippetsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SnippetsHeader { Task { await viewModel.presentNew() } }
            if viewModel.isEmpty {
                SnippetsEmptyView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView { SnippetsGrid(viewModel: viewModel) }
            }
            SnippetsSayPrefixRow(viewModel: viewModel)
        }
        .padding(20)
        .sheet(isPresented: sheetBinding) {
            NewSnippetSheet(viewModel: viewModel)
        }
    }

    private var sheetBinding: Binding<Bool> {
        Binding(get: { viewModel.sheet != nil }, set: { if !$0 { viewModel.cancelSheet() } })
    }
}

/// The intro + "+ New snippet" header (design MW-04) — its own view (review M6) so
/// `SnippetsRenderTests`' preview can share this exact copy with production instead of re-typing it,
/// which would let a copy change drift out of the design-fidelity gate unnoticed.
struct SnippetsHeader: View {
    let newSnippet: () -> Void

    init(newSnippet: @escaping () -> Void) {
        self.newSnippet = newSnippet
    }

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 16) {
            Text("Say a trigger and VoxFlow inserts the full text. Triggers work in every app.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520, alignment: .leading)
            Spacer(minLength: 0)
            Button("+ New snippet", action: newSnippet)
                .buttonStyle(.borderedProminent)
        }
    }
}

/// The card grid's content — two flexible columns of `SnippetCardView`. Factored out of
/// `SnippetsPageBody` (which wraps this in a `ScrollView`) so `SnippetsRenderTests` can render the
/// exact same grid without a live `ScrollView` (blank under `ImageRenderer`, same issue
/// `DictionaryList`'s doc comment describes).
struct SnippetsGrid: View {
    let viewModel: SnippetsViewModel
    private let columns = [GridItem(.flexible(), spacing: 16, alignment: .top),
                           GridItem(.flexible(), spacing: 16, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(viewModel.snippets) { snippet in
                SnippetCardView(snippet: snippet, viewModel: viewModel)
            }
        }
    }
}

/// One snippet card (design MW-04): monospace trigger chip, "Used N×", a 3-line body preview, and
/// hover actions (Edit/Delete) — same hover-reveal pattern as `DictionaryRowView`.
struct SnippetCardView: View {
    let snippet: Snippet
    let viewModel: SnippetsViewModel
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                triggerChip
                Spacer(minLength: 8)
                if isHovering { actions } else { usesLabel }
            }
            Text(snippet.body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            // "Only in {app}" caption: implementation-authored copy (review M4) — neither the canvas
            // nor the brief shows a scoped-snippet card caption; flagged for an explicit owner call
            // rather than silently assumed. Kept because an app-scoped card with no on-card
            // indication of its scope would be a worse (silently misleading) default.
            if let appName = snippet.onlyInAppName {
                Text("Only in \(appName)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.secondary.opacity(0.12)))
        .onHover { isHovering = $0 }
    }

    private var triggerChip: some View {
        Text(snippet.trigger)
            .font(.system(.callout, design: .monospaced).weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var usesLabel: some View {
        Text("Used \(snippet.uses)\u{00d7}")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button("Edit") { Task { await viewModel.editExisting(snippet) } }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            Button("Delete") { viewModel.delete(snippet) }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
        }
        .font(.caption)
    }
}

/// "No snippets" (design 2d MW-04e): one icon, one line of body copy, one action that opens "New
/// snippet" prefilled with `/sig`.
struct SnippetsEmptyView: View {
    let viewModel: SnippetsViewModel

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.secondary.opacity(0.1)).frame(width: 56, height: 56)
                Image(systemName: "text.append").font(.system(size: 22)).foregroundStyle(.secondary)
            }
            Text("No snippets").font(.headline)
            Text("Say a short trigger, get a full block of text. Start with a signature.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("Create /sig") { Task { await viewModel.presentNew(prefillTrigger: "/sig") } }
                .buttonStyle(.borderedProminent)
        }
    }
}

/// The bottom "Say 'snippet' before the trigger" toggle row (design MW-04) — same visual pattern as
/// `DictionaryContactsRow`.
struct SnippetsSayPrefixRow: View {
    let viewModel: SnippetsViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Say \u{201c}snippet\u{201d} before the trigger").fontWeight(.medium)
                Text("Avoids accidental expansion when a trigger word appears in normal speech.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: toggleBinding)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.secondary.opacity(0.12)))
    }

    private var toggleBinding: Binding<Bool> {
        Binding(get: { viewModel.sayPrefix }, set: { viewModel.sayPrefix = $0 })
    }
}
