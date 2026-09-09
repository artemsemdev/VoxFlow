import SwiftUI
import VoxFlowModels

/// ONB-04 "Download your speech model" — one row (`ModelsViewModel`'s default speech row) with the
/// same states `ModelsSettingsView` shows in Settings › Models, plus the smaller-model hint and the
/// no-sign-in footer. Completion (row `.installed`) auto-advances — via `OnboardingViewModel.download()`,
/// and via `retryDownload(_:)`/`useSmallerModelInsufficientSpace()` for the ONB-04a alert-driven paths
/// (N-4: none of the three routes bypass the shared `advanceIfInstalled()` check).
struct ModelStepView: View {
    let viewModel: OnboardingViewModel

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text("Download your speech model").font(.system(size: 24, weight: .bold))
                Text("This is the only download VoxFlow ever makes.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            if let row = viewModel.modelRow {
                modelCard(row)
            } else {
                ProgressView().frame(height: 96)
            }
            if let smaller = viewModel.smallerModel {
                Button {
                    viewModel.useSmallerModel()
                } label: {
                    (Text("Have an 8 GB Mac? ").foregroundStyle(.secondary)
                     + Text("Use the \(ModelsViewModel.gigabytes(smaller.sizeInBytes)) model instead.")
                         .foregroundStyle(Color.accentColor))
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
            Text("You can start dictating as soon as it finishes — no sign-in, no internet needed after this.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: 480)
        // ONB-04a: the same alerts Settings › Models presents (SYS-DISK, offline, download failed) —
        // duplicated here rather than extracted into a shared modifier since `ModelsSettingsView.swift`
        // is outside this task's touched files; the mapping (title/message/buttons) matches it exactly.
        .alert(alertTitle, isPresented: alertIsPresented, presenting: viewModel.models.alert) { alert in
            alertButtons(alert)
        } message: { alert in
            Text(alertMessage(alert))
        }
    }

    // MARK: Alerts (ONB-04a) — mirrors ModelsSettingsView's alert mapping

    private var alertIsPresented: Binding<Bool> {
        Binding(get: { viewModel.models.alert != nil }, set: { isPresented in if !isPresented { viewModel.models.dismissAlert() } })
    }

    private var alertTitle: String {
        switch viewModel.models.alert {
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
            if let smaller = viewModel.models.smallerSpeechModel(than: failed) {
                Button("Use the \(ModelsViewModel.gigabytes(smaller.sizeInBytes)) model") { Task { await viewModel.useSmallerModelInsufficientSpace() } }
            }
            Button("Free up space…") { viewModel.models.openStorageSettings() }
            Button("Cancel", role: .cancel) { viewModel.models.dismissAlert() }
        case .removeModel:
            Button("Remove", role: .destructive) { Task { await viewModel.models.confirmRemove() } }
            Button("Cancel", role: .cancel) { viewModel.models.dismissAlert() }
        case .cannotRemoveOnlyModel:
            Button("OK", role: .cancel) { viewModel.models.dismissAlert() }
        case .downloadFailed(let failed, _):
            Button("Retry download") { Task { await viewModel.retryDownload(failed) } }
            Button("Cancel", role: .cancel) { viewModel.models.dismissAlert() }
        case .offline(let paused, _, _, _):
            Button("OK", role: .cancel) { viewModel.models.dismissAlert() }
            Button("Cancel download") { Task { await viewModel.models.discardDownload(paused) } }
        }
    }

    private func modelCard(_ row: ModelsViewModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(row.model.displayName).font(.system(size: 15, weight: .semibold))
                // The catalog's own recommendation (shown before install), not `row.isDefault` —
                // that only reflects which *installed* model dictation currently uses (ModelStore
                // .defaultModel considers installed models only), so it's always false pre-download.
                if row.model.isDefault {
                    Text("RECOMMENDED")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
            }
            Text(row.state == .installed ? "Installed" : viewModel.downloadText(for: row))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if case .downloading(let written, let total) = row.state {
                ProgressView(value: Double(written), total: Double(max(total, 1)))
                    .progressViewStyle(.linear)
            }
            trailing(row)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.black.opacity(0.06)))
    }

    @ViewBuilder
    private func trailing(_ row: ModelsViewModel.Row) -> some View {
        switch row.state {
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.onDevice)
        case .notInstalled:
            Button("Download") { Task { await viewModel.download() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!row.isAvailable)
        case .downloading:
            Button("Pause") { Task { await viewModel.pause() } }
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .paused:
            Button("Resume") { Task { await viewModel.download() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .verifying:
            ProgressView().controlSize(.small)
        }
    }
}
