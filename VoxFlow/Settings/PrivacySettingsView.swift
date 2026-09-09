import SwiftUI

/// Settings › Privacy (design ST-05, ST-05d): thin `ScrollView` wrapper around
/// `PrivacySettingsBody` — split the same way `HistoryPage`/`HistoryPageBody` are, so
/// `SettingsRenderTests` can render the content directly (`ImageRenderer` doesn't reliably capture
/// `ScrollView`).
struct PrivacySettingsView: View {
    let privacy: PrivacyViewModel

    var body: some View {
        ScrollView { PrivacySettingsBody(privacy: privacy) }
            .frame(maxWidth: .infinity)
    }
}

struct PrivacySettingsBody: View {
    let privacy: PrivacyViewModel

    private static let retentionChoices: [(days: Int, label: String)] = [
        (7, "7 days"), (30, "30 days"), (90, "90 days"), (365, "1 year"), (0, "Never"),
    ]

    var body: some View {
        @Bindable var settings = privacy.settings
        VStack(alignment: .leading, spacing: 18) {
            header

            VStack(spacing: 0) {
                keepHistoryRow(settings: settings)
                Divider().padding(.leading, 16)
                retentionRow(settings: settings)
                Divider().padding(.leading, 16)
                encryptRow(settings: settings)
                Divider().padding(.leading, 16)
                excludedAppsRow
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Button("Delete all history…") { Task { await privacy.requestDeleteAll() } }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
        }
        .padding(20)
        .frame(maxWidth: 640, alignment: .leading)
        .alert(PrivacyViewModel.deleteAllTitle, isPresented: alertIsPresented, presenting: privacy.alert) { alert in
            alertButtons(alert)
        } message: { alert in
            Text(alertMessage(alert))
        }
    }

    // MARK: header (ST-05 "Everything stays on your Mac")

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("Everything stays on your Mac").fontWeight(.semibold)
            }
            Text("VoxFlow has no account, no analytics and no cloud. Audio is processed in memory and discarded. The only outgoing connection it can make is a model download you start yourself.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                statLine("Network requests since install:", value: "0")
                statLine("Audio stored:", value: "none")
            }
            .font(.caption.weight(.medium))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.25)))
    }

    private func statLine(_ label: String, value: String) -> some View {
        (Text(label) + Text(" ") + Text(value).fontWeight(.semibold))
    }

    // MARK: rows

    private func keepHistoryRow(settings: DictationSettings) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Keep dictation history")
                Text("Text only — audio is never saved").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Keep dictation history", isOn: bindingFor(settings, \.keepHistory)).labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func retentionRow(settings: DictationSettings) -> some View {
        HStack {
            Text("Delete history after")
            Spacer()
            Picker("Delete history after", selection: bindingFor(settings, \.retentionDays)) {
                ForEach(Self.retentionChoices, id: \.days) { choice in
                    Text(choice.label).tag(choice.days)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 140)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func encryptRow(settings: DictationSettings) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Encrypt history at rest")
                Text(privacy.encryptionSubtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Encrypt history at rest", isOn: bindingFor(settings, \.encryptHistory)).labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var excludedAppsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Never record in")
            FlowLayoutStack {
                ForEach(privacy.excludedApps, id: \.bundleID) { app in
                    excludedAppChip(app)
                }
                Button("+ Add") { Task { await privacy.addApp() } }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func excludedAppChip(_ app: (bundleID: String, name: String)) -> some View {
        HStack(spacing: 4) {
            Text(app.name)
            Button {
                privacy.remove(app.bundleID)
            } label: {
                Image(systemName: "xmark.circle.fill").font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    /// `Toggle`/`Picker` need a two-way `Binding`; `@Bindable`'s generated `$settings.keepHistory`
    /// already provides that, but since this view reads through `privacy.settings` (not its own
    /// `@Bindable` stored property) the local `@Bindable var settings` above is what supplies it —
    /// this helper just names the key path so each row reads cleanly.
    private func bindingFor<Value>(_ settings: DictationSettings, _ keyPath: ReferenceWritableKeyPath<DictationSettings, Value>) -> Binding<Value> {
        Binding(get: { settings[keyPath: keyPath] }, set: { settings[keyPath: keyPath] = $0 })
    }

    // MARK: ST-05d alert

    private var alertIsPresented: Binding<Bool> {
        Binding(get: { privacy.alert != nil }, set: { isPresented in if !isPresented { privacy.dismissAlert() } })
    }

    private func alertMessage(_ alert: PrivacyViewModel.Alert) -> String {
        switch alert {
        case .deleteAll(let count): PrivacyViewModel.deleteAllMessage(count: count)
        }
    }

    @ViewBuilder
    private func alertButtons(_ alert: PrivacyViewModel.Alert) -> some View {
        switch alert {
        case .deleteAll:
            Button("Delete", role: .destructive) { Task { await privacy.confirmDeleteAll() } }
            Button("Cancel", role: .cancel) { privacy.dismissAlert() }
        }
    }
}

/// A left-aligned wrap layout for the "Never record in" chips + "+ Add" — plain `HStack` would
/// clip or overflow once the excluded-apps list grows past one row's width.
private struct FlowLayoutStack: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var (width, height): (CGFloat, CGFloat) = (0, 0)
        var (rowWidth, rowHeight): (CGFloat, CGFloat) = (0, 0)
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                width = max(width, rowWidth)
                height += rowHeight + spacing
                (rowWidth, rowHeight) = (0, 0)
            }
            rowWidth += size.width + (rowWidth > 0 ? spacing : 0)
            rowHeight = max(rowHeight, size.height)
        }
        width = max(width, rowWidth)
        height += rowHeight
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var origin = bounds.origin
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x + size.width > bounds.maxX, origin.x > bounds.minX {
                origin.x = bounds.minX
                origin.y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: origin, proposal: .unspecified)
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
