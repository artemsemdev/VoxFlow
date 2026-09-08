import SwiftUI
import VoxFlowCore

/// Bottom toolbar (design 1c Files › Output format / Batch mode / Timestamps / Language / Save to;
/// controller ruling 3 places this at the bottom rather than the design's side panel).
struct FilesToolbar: View {
    let model: FilesViewModel
    @Bindable var settings: FilesSettings
    @State private var isFolderPickerPresented = false

    /// Auto-detect (nil) plus the design's six languages (2f / 1c).
    private static let languages: [(code: String?, name: String)] = [
        (nil, "Auto-detect"),
        ("en", "English"),
        ("es", "Español"),
        ("fr", "Français"),
        ("de", "Deutsch"),
        ("ja", "日本語"),
        ("pt", "Português"),
    ]

    /// "Save to " + the abbreviated output folder (design 1c) — the folder button's own label.
    var folderTitle: String { "Save to \(ResultViewModel.abbreviate(settings.outputFolder))" }

    var body: some View {
        VStack(spacing: 10) {
            Divider()
            HStack(alignment: .bottom, spacing: 20) {
                formatPicker
                batchToggle
                Toggle("Timestamps", isOn: $settings.timestamps)
                    .disabled(!settings.outputFormat.supportsTimestampToggle)
                    .help(settings.outputFormat.supportsTimestampToggle ? "" : "SRT, VTT and JSON always include timestamps")
                Spacer()
            }
            HStack(alignment: .bottom, spacing: 20) {
                languagePicker
                saveFolderButton
                Spacer()
                Button(model.transcribeButtonTitle) { Task { await model.transcribeAll() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canTranscribe)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .fileImporter(isPresented: $isFolderPickerPresented, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { settings.outputFolder = url }
        }
    }

    // Caption above the control (not the control's own label) so a segmented picker never wraps
    // its option titles vertically to fit — `.fixedSize()` keeps the caption from being compressed
    // by its siblings, and `.labelsHidden()` on the control below drops the (redundant) built-in
    // label SwiftUI would otherwise still reserve room for.
    private var formatPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Output format")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
            Picker("Output format", selection: $settings.outputFormat) {
                ForEach(OutputFormat.allCases, id: \.self) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
        }
    }

    private var batchToggle: some View {
        Toggle(isOn: $settings.batchMode) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Batch mode")
                Text("One output folder, shared settings")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var languagePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Language")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
            Picker("Language", selection: $settings.language) {
                ForEach(Self.languages, id: \.name) { language in
                    Text(language.name).tag(language.code)
                }
            }
            .labelsHidden()
            .frame(width: 180)
        }
    }

    private var saveFolderButton: some View {
        Button {
            isFolderPickerPresented = true
        } label: {
            Label(folderTitle, systemImage: "folder")
        }
        .buttonStyle(.link)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(settings.outputFolder.path)
        .frame(maxWidth: 260, alignment: .leading)
    }
}
