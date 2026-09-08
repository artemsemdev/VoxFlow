import SwiftUI
import VoxFlowCore
import VoxFlowModels

/// Settings › Models (design ST-03): two grouped sections, state-specific trailing controls per
/// row, and the alerts `ModelsViewModel` surfaces (SYS-DISK, ST-03d, ST-03v, ST-03o).
struct ModelsSettingsView: View {
    let model: ModelsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section(title: "Speech recognition", rows: model.speechRows)
                section(title: "Cleanup & styles", rows: model.styleRows)
                Text(model.footerText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .task { await model.refresh() }
        // Re-triggered whenever `isAnyRowActive` flips — a download starting (from this view or
        // `useSmallerModelInstead`/`resume`) or `refresh()` itself picking one up — since SwiftUI
        // cancels and restarts a `.task(id:)` when its id changes. `pollWhileActive()` then exits on
        // its own once nothing is left downloading/verifying, instead of sleeping forever (M6).
        .task(id: isAnyRowActive) { await pollWhileActive() }
        .alert(alertTitle, isPresented: alertIsPresented, presenting: model.alert) { alert in
            alertButtons(alert)
        } message: { alert in
            Text(alertMessage(alert))
        }
    }

    private var isAnyRowActive: Bool {
        (model.speechRows + model.styleRows).contains {
            switch $0.state {
            case .downloading, .verifying: true
            default: false
            }
        }
    }

    /// Poll for display only — the row states themselves are already pushed live by `download()`'s
    /// consumption of `store.install`'s stream; this just keeps derived text (progress, footer)
    /// current while something is in flight, at most once a second.
    private func pollWhileActive() async {
        guard isAnyRowActive else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, isAnyRowActive else { return }
            await model.refresh()
        }
    }

    // MARK: Sections & rows

    private func section(title: String, rows: [ModelsViewModel.Row]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    rowView(row)
                    if index < rows.count - 1 {
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func rowView(_ row: ModelsViewModel.Row) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(row.model.displayName).fontWeight(.medium)
                    if row.isDefault {
                        Text("DEFAULT")
                            .font(.system(size: 10.5, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                rowSubtitle(row)
                if case .downloading(let written, let total) = row.state {
                    ProgressView(value: Double(written), total: Double(max(total, 1)))
                        .progressViewStyle(.linear)
                } else if case .verifying = row.state {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }
            Spacer()
            trailingControl(row)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func rowSubtitle(_ row: ModelsViewModel.Row) -> some View {
        switch row.state {
        case .verifying:
            Text("Verifying download… checking \(row.sizeText) against the published checksum")
                .font(.caption).foregroundStyle(.secondary)
        case .downloading:
            Text(model.downloadText(for: row))
                .font(.caption).foregroundStyle(.secondary)
        default:
            Text(row.subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func trailingControl(_ row: ModelsViewModel.Row) -> some View {
        switch row.state {
        case .installed:
            HStack(spacing: 10) {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                Button("Remove…") { Task { await model.requestRemove(row.model) } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        case .notInstalled:
            Button("Download") { Task { await model.download(row.model) } }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!row.isAvailable)
                .help(row.isAvailable ? "" : "Available in a later version")
        case .downloading:
            Button("Pause") { Task { await model.pause(row.model) } }
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .paused:
            Button("Resume") { Task { await model.resume(row.model) } }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .verifying:
            EmptyView()
        }
    }

    // MARK: Alerts

    private var alertIsPresented: Binding<Bool> {
        Binding(get: { model.alert != nil }, set: { isPresented in if !isPresented { model.dismissAlert() } })
    }

    private var alertTitle: String {
        switch model.alert {
        case .insufficientSpace: ModelsViewModel.insufficientSpaceTitle
        case .removeModel(let m, _): ModelsViewModel.removeTitle(m)
        case .cannotRemoveOnlyModel: ModelsViewModel.cannotRemoveOnlyModelTitle
        case .downloadFailed(let m, _): m.displayName
        case .offline: ModelsViewModel.offlineTitle
        case nil: ""
        }
    }

    private func alertMessage(_ alert: ModelsViewModel.Alert) -> String {
        switch alert {
        case .insufficientSpace(let m, _, let available): ModelsViewModel.insufficientSpaceMessage(m, available: available)
        case .removeModel(let m, let keeps): ModelsViewModel.removeMessage(m, keeps: keeps)
        case .cannotRemoveOnlyModel: ModelsViewModel.cannotRemoveOnlyModelMessage
        case .downloadFailed(_, let reason): reason
        case .offline(_, let written, let total, let dictationKeepsWorking):
            ModelsViewModel.offlineMessage(bytesWritten: written, total: total, dictationKeepsWorking: dictationKeepsWorking)
        }
    }

    @ViewBuilder
    private func alertButtons(_ alert: ModelsViewModel.Alert) -> some View {
        switch alert {
        case .insufficientSpace(let failed, _, _):
            if let smaller = model.smallerSpeechModel(than: failed) {
                Button("Use the \(ModelsViewModel.gigabytes(smaller.sizeInBytes)) model") { Task { await model.useSmallerModelInstead() } }
            }
            Button("Free up space…") { model.openStorageSettings() }
            Button("Cancel", role: .cancel) { model.dismissAlert() }
        case .removeModel:
            // Design ST-03d: Remove is destructive but *not* the default action — Cancel is safer
            // to trigger by accident (e.g. a stray Return keypress).
            Button("Remove", role: .destructive) { Task { await model.confirmRemove() } }
            Button("Cancel", role: .cancel) { model.dismissAlert() }
        case .cannotRemoveOnlyModel:
            Button("OK", role: .cancel) { model.dismissAlert() }
        case .downloadFailed(let failed, _):
            Button("Retry download") { Task { await model.download(failed) } }
            Button("Cancel", role: .cancel) { model.dismissAlert() }
        case .offline(let paused, _, _, _):
            Button("OK", role: .cancel) { model.dismissAlert() }
            Button("Cancel download") { Task { await model.discardDownload(paused) } }
        }
    }
}
