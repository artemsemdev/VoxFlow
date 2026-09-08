import SwiftUI
import VoxFlowCore
import VoxFlowFiles

/// The transcript result screen (design 2f), shown inside the Files page in place of the queue —
/// not a sheet (controller ruling 6). Builds its own `ResultViewModel` from the row that was opened.
struct TranscriptResultView: View {
    let onBack: () -> Void
    @State private var resultModel: ResultViewModel

    init(result: FilesViewModel.ExportedResult, settings: FilesSettings, onBack: @escaping () -> Void) {
        self.onBack = onBack
        _resultModel = State(wrappedValue: ResultViewModel(
            document: result.document, format: settings.outputFormat, timestamps: settings.timestamps,
            // No per-job record of "was auto-detect requested" survives onto `QueueItem`/
            // `TranscriptDocument` — this reads the *current* Files setting as the best available
            // proxy for what the job that produced this transcript most likely used.
            autoDetectedLanguage: settings.language == nil, savedURL: result.url,
            exporter: { AppServices.shared.exporter }, pasteboard: SystemPasteboard(), revealer: FinderRevealer()))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchBar
            Divider()
            segmentList
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button("‹ Queue", action: onBack)
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(resultModel.document.baseName).fontWeight(.semibold)
                Text(resultModel.metaLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 12)
            Picker("Format", selection: $resultModel.format) {
                ForEach(OutputFormat.allCases, id: \.self) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
            Button("Copy") { resultModel.copy() }
            Button("Save as…") {
                SavePanel.save(baseName: resultModel.document.baseName, format: resultModel.format, contents: resultModel.rendered)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }

    private var searchBar: some View {
        // "Segment length" and "Apply Casual cleanup" (design 2f) aren't built here — they're
        // phase 4/5 (segmentation controls, style rewriting), out of scope for this UI task.
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in transcript", text: $resultModel.searchText)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var segmentList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(Array(resultModel.visibleSegments.enumerated()), id: \.offset) { _, segment in
                    let index = (resultModel.document.transcript.segments.firstIndex(of: segment) ?? 0) + 1
                    HStack(alignment: .top, spacing: 18) {
                        Text("\(index)\n\(TimeCode.srt(segment.start)) → \(TimeCode.srt(segment.end))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 190, alignment: .leading)
                        Text(segment.text)
                            .font(.system(.callout, design: .monospaced))
                    }
                }
            }
            .padding(16)
        }
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                if let message = resultModel.exportMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                if resultModel.savedURL != nil {
                    Button("Reveal in Finder") { resultModel.reveal() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            }
            Spacer()
            HStack(spacing: 4) {
                Text("Also export:").font(.caption).foregroundStyle(.secondary)
                ForEach(resultModel.otherFormats, id: \.self) { format in
                    Button(format.displayName) { _ = try? resultModel.exportAlso(format) }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
                Text("— instant, no re-processing").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
