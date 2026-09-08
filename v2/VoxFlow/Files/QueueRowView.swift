import SwiftUI
import VoxFlowCore
import VoxFlowFiles

/// One queue row (design MW-06 / MW-06x): filename, a `2×` badge past the first duplicate drop, and
/// a status-specific trailing area. Tapping a done row opens the transcript (design 2f); every
/// other status just shows its own controls.
struct QueueRowView: View {
    let item: QueueItem
    let model: FilesViewModel
    private let revealer: any FileRevealing = FinderRevealer()

    var body: some View {
        Group {
            switch item.status {
            case .queued: queuedRow
            case .running(let progress): runningRow(progress)
            case .done: doneRow
            case .failed(let error): failedRow(error)
            case .cancelled: cancelledRow
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            if case .done = item.status { model.open(item) }
        }
    }

    private var nameLine: some View {
        HStack(spacing: 6) {
            Text(item.url.lastPathComponent).fontWeight(.medium)
            if item.duplicates > 1 {
                Text("\(item.duplicates)×")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
        }
    }

    private var durationText: String { item.duration.map(TimeCode.short) ?? "--:--" }

    private var queuedRow: some View {
        HStack {
            nameLine
            Spacer()
            Text("\(durationText) · queued")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func runningRow(_ progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                nameLine
                Spacer()
                Text("\(durationText) · \(FilesViewModel.progressText(for: progress))\(etaSuffix)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Stop") { Task { await model.requestStop(item) } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            ProgressView(value: progress)
                .accessibilityValue("\(Int((progress * 100).rounded()))%")
        }
    }

    private var etaSuffix: String {
        guard let eta = model.etaText(for: item) else { return "" }
        return " · \(eta)"
    }

    private var doneRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                nameLine
                Spacer()
                Text("\(durationText) · done")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let url = model.exported(for: item) {
                    Button("Reveal in Finder") { revealer.reveal(url) }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            }
            if let error = model.exportError(for: item) {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    /// `.unsupportedType` shows an orange badge (it's a drop-time gate, not an engine failure);
    /// every other case shows red.
    private func failedRow(_ error: FileTranscriptionError) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(FilesViewModel.isUnsupportedFailure(error) ? Color.orange : Color.red)
                .frame(width: 18, height: 18)
                .overlay(Text("!").font(.caption2.weight(.heavy)).foregroundStyle(.white))
                // Purely decorative — `FilesViewModel.failureMessage(error)` right next to it already
                // says what's wrong, so VoiceOver would otherwise read a bare, unexplained "!".
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                nameLine
                Text(FilesViewModel.failureMessage(error))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if FilesViewModel.canRetryFailure(error) {
                Button("Retry") { Task { await model.retry(item) } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Button("Remove") { Task { await model.remove(item) } }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    /// A stopped-but-kept row (design MW-06c: "the file stays in the queue"). Not itself part of
    /// MW-06x's copy table — the brief only specifies the two `.failed` variants — so this reuses
    /// the same Retry/Remove pattern with neutral styling.
    private var cancelledRow: some View {
        HStack {
            nameLine
            Spacer()
            Text("stopped")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Retry") { Task { await model.retry(item) } }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button("Remove") { Task { await model.remove(item) } }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}
