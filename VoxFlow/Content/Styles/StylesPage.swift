import SwiftUI
import VoxFlowCore
import VoxFlowStorage

/// The Styles page (design MW-05, 05a): thin `AppServices` wrapper around `StylesPageBody`, which
/// holds the actual layout so `StylesRenderTests` can render exactly the same view instead of a
/// hand-copied approximation (same split `DictionaryPage`/`DictionaryPageBody` pattern uses).
struct StylesPage: View {
    @Environment(AppServices.self) private var services
    private var model: StylesViewModel { services.stylesViewModel }

    var body: some View {
        StylesPageBody(viewModel: model)
            .navigationTitle("Styles")
            .task { await model.load() }
    }
}

/// The page content below the navigation chrome: intro, the "You said:" sample, the three
/// default-style cards, the "Per-app overrides" card, the two toggles, and the "Add app override"
/// sheet.
struct StylesPageBody: View {
    let viewModel: StylesViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                intro
                saidBlock
                cards
                OverridesCard(viewModel: viewModel)
                toggles
            }
            .padding(20)
        }
        .sheet(isPresented: sheetBinding) {
            AddAppOverrideSheet(viewModel: viewModel)
        }
    }

    private var intro: some View {
        Text("Choose how VoxFlow cleans up what you say. Same words in, different text out — all rewritten by the on-device model.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: 560, alignment: .leading)
    }

    private var saidBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("You said:").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text("\u{201c}\(StylesViewModel.saidSample)\u{201d}")
                .font(.callout)
                .italic()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var cards: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(StylesViewModel.cards, id: \.style) { card in
                StyleCardView(card: card, isSelected: viewModel.defaultStyle == card.style) {
                    viewModel.defaultStyle = card.style
                }
            }
        }
    }

    private var toggles: some View {
        VStack(spacing: 10) {
            ToggleRow(title: "Remove filler words (um, uh, like)", isOn: removeFillersBinding)
            ToggleRow(title: "Auto-punctuate and capitalize", isOn: autoPunctuateBinding)
        }
    }

    private var sheetBinding: Binding<Bool> {
        Binding(get: { viewModel.addAppSheet != nil }, set: { if !$0 { viewModel.cancelAddApp() } })
    }

    private var removeFillersBinding: Binding<Bool> {
        Binding(get: { viewModel.removeFillers }, set: { viewModel.removeFillers = $0 })
    }

    private var autoPunctuateBinding: Binding<Bool> {
        Binding(get: { viewModel.autoPunctuate }, set: { viewModel.autoPunctuate = $0 })
    }
}

/// One default-style card (design MW-05): sample + description, selectable, highlighted while
/// selected.
struct StyleCardView: View {
    let card: StyleCard
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(card.style.displayName).font(.subheadline.weight(.semibold))
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                    }
                }
                Text("\u{201c}\(card.sample)\u{201d}")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(card.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.12), lineWidth: isSelected ? 2 : 1))
        }
        .buttonStyle(.plain)
    }
}

/// "Per-app overrides" (design MW-05): "+ Add app" plus a row per override (app name, style picker,
/// remove button).
struct OverridesCard: View {
    let viewModel: StylesViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Per-app overrides").font(.headline)
                Spacer()
                Button("+ Add app") { viewModel.presentAddApp() }
                    .buttonStyle(.bordered)
            }
            if viewModel.overrides.isEmpty {
                Text("No overrides yet — every app uses the default style above.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(viewModel.overrides, id: \.bundleID) { override in
                        OverrideRow(override: override, viewModel: viewModel)
                        Divider()
                    }
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.secondary.opacity(0.12)))
    }
}

/// One "Per-app overrides" row: app name, a style picker ("Verbatim (no cleanup)" for verbatim), a
/// remove button.
struct OverrideRow: View {
    let override: StyleOverride
    let viewModel: StylesViewModel

    var body: some View {
        HStack(spacing: 12) {
            Text(override.appName).frame(maxWidth: .infinity, alignment: .leading)
            Picker("", selection: styleBinding) {
                ForEach(StylesViewModel.overrideStyles, id: \.self) { style in
                    Text(style == .verbatim ? "Verbatim (no cleanup)" : style.displayName).tag(style)
                }
            }
            .labelsHidden()
            .frame(width: 180)
            Button("Remove") { viewModel.removeOverride(override) }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
        }
        .font(.callout)
        .padding(.vertical, 10)
    }

    private var styleBinding: Binding<TextStyle> {
        Binding(get: { override.style }, set: { newValue in Task { await viewModel.changeOverrideStyle(override, to: newValue) } })
    }
}

/// A labeled switch row — same visual pattern as `DictionaryContactsRow`/`SnippetsSayPrefixRow`, just
/// without the subtitle line (the Styles toggles are single-line, design MW-05).
struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title).fontWeight(.medium)
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.secondary.opacity(0.12)))
    }
}
