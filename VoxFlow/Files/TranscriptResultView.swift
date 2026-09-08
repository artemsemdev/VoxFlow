import SwiftUI
import VoxFlowCore
import VoxFlowFiles

/// The transcript result screen (design 2f), shown inside the Files page in place of the queue —
/// not a sheet (controller ruling 6). Builds its own `ResultViewModel` from the row that was opened.
struct TranscriptResultView: View {
    @Bindable var resultModel: ResultViewModel
    let onBack: () -> Void

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
                .accessibilityLabel("Back to queue")
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
                switch SavePanel.save(baseName: resultModel.document.baseName, format: resultModel.format, contents: resultModel.rendered) {
                case .saved, .cancelled: break
                case .failed(let error): resultModel.report(error: error)
                }
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
                ForEach(Array(resultModel.visibleIndexedSegments.enumerated()), id: \.offset) { _, indexed in
                    HStack(alignment: .top, spacing: 18) {
                        Text("\(indexed.index)\n\(TimeCode.srt(indexed.segment.start)) → \(TimeCode.srt(indexed.segment.end))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 190, alignment: .leading)
                        Text(indexed.segment.text)
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
                    Button(format.displayName) {
                        do { try resultModel.exportAlso(format) } catch { resultModel.report(error: error) }
                    }
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
