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
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find in transcript", text: $resultModel.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text("Segment length").font(.caption).foregroundStyle(.secondary)
            SegmentLengthPicker(selection: $resultModel.segmentLength)
            Toggle(resultModel.cleanupLabel, isOn: $resultModel.applyCleanup)
                .toggleStyle(.checkbox)
                .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var segmentList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(Array(resultModel.visibleIndexedSegments.enumerated()), id: \.offset) { _, indexed in
                    TranscriptSegmentRow(index: indexed.index, segment: indexed.segment)
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

/// The compact white popup and blue chevrons from canvas 2f, with native menu selection.
struct SegmentLengthPicker: View {
    @Binding var selection: SegmentLength
    @State private var showingOptions = false

    var body: some View {
        Button { showingOptions = true } label: {
            HStack(spacing: 6) {
                Text(selection.displayName).font(.system(size: 12))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 4))
            }
            .padding(.leading, 10).padding(.trailing, 6).frame(height: 24)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
        }
        .buttonStyle(.plain).fixedSize()
        .accessibilityLabel("Segment length").accessibilityValue(selection.displayName)
        .popover(isPresented: $showingOptions, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SegmentLength.allCases, id: \.self) { length in
                    Button {
                        selection = length
                        showingOptions = false
                    } label: {
                        HStack {
                            Image(systemName: "checkmark").opacity(selection == length ? 1 : 0)
                            Text(length.displayName)
                            Spacer()
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == length ? [.isSelected] : [])
                }
            }
            .padding(6).frame(width: 150)
        }
    }
}

/// One transcript row (position, timecode, text) — its own type (not inline in `segmentList`'s
/// `ForEach`) so `FilesRenderTests` can render rows outside a live `ScrollView`, which rasterizes
/// blank under `ImageRenderer`, without hand-retyping the row and risking drift from production
/// (the same reasoning `StylesRenderTests`' `AppListRow` reuse documents).
struct TranscriptSegmentRow: View {
    let index: Int
    let segment: TranscriptSegment

    var body: some View {
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
