import SwiftUI
import VoxFlowModels

/// ONB-04 "Download your speech model" — one row (`ModelsViewModel`'s default speech row) with the
/// same states `ModelsSettingsView` shows in Settings › Models, plus the smaller-model hint and the
/// no-sign-in footer. Completion (row `.installed`) auto-advances via `OnboardingViewModel.download()`.
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
                (Text("Have an 8 GB Mac? ").foregroundStyle(.secondary)
                 + Text("Use the \(ModelsViewModel.gigabytes(smaller.sizeInBytes)) model instead.")
                     .foregroundStyle(Color.accentColor))
                    .font(.system(size: 12))
                    .onTapGesture { viewModel.useSmallerModel() }
            }
            Text("You can start dictating as soon as it finishes — no sign-in, no internet needed after this.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: 480)
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
