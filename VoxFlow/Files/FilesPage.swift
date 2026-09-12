import SwiftUI
import UniformTypeIdentifiers
import VoxFlowCore
import VoxFlowFiles
import VoxFlowModels

/// The Files page (design 1c Files, MW-06): drop zone/queue + toolbar, replaced by the transcript
/// result view (design 2f) when a row is opened — not a sheet (controller ruling 6).
struct FilesPage: View {
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation
    /// Built once per opened row (not per render) in `.onChange` below — `TranscriptResultView`
    /// only ever receives an already-built `ResultViewModel`, never constructs its own.
    @State private var resultModel: ResultViewModel?

    private var model: FilesViewModel { services.filesViewModel }

    var body: some View {
        Group {
            if let resultModel {
                TranscriptResultView(resultModel: resultModel, onBack: model.closeResult)
            } else {
                queueBody
            }
        }
        .navigationTitle("Files")
        .task { await model.refreshModelState() }
        .onChange(of: model.selected?.item.id, initial: true) { _, _ in updateResultModel() }
        .alert(alertTitle, isPresented: alertIsPresented, presenting: model.confirmation) { confirmation in
            alertButtons(confirmation)
        } message: { confirmation in
            Text(alertMessage(confirmation))
        }
        // At the outermost container (not scoped to `queueBody`) so File › Open
        // (`Navigation.requestFileImport`) always has somewhere to present from, even when it fires
        // while the result view is showing — the command itself closes the result first, but the two
        // state changes land in the same view update, and only the outer container is guaranteed to
        // still be part of the tree either way.
        .fileImporter(isPresented: requestFileImportBinding, allowedContentTypes: [.audio, .movie], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { await model.addFiles(urls) }
            }
            navigation.requestFileImport = false
        }
    }

    private func updateResultModel() {
        guard let selected = model.selected else {
            resultModel = nil
            return
        }
        let settings = services.filesSettings
        let modelDisplayName = ModelCatalog.model(id: selected.document.modelID)?.displayName ?? selected.document.modelID
        // "Apply {Style} cleanup" (design 2f, plan ruling 6) always styles for the *default* tone,
        // not any per-app override — a file transcript has no "frontmost app" to key an override by.
        let styling = services.stylingSettings.snapshot
        resultModel = ResultViewModel(
            document: selected.document, format: settings.outputFormat, timestamps: settings.timestamps,
            // No per-job record of "was auto-detect requested" survives onto `QueueItem`/
            // `TranscriptDocument` — this reads the *current* Files setting as the best available
            // proxy for what the job that produced this transcript most likely used.
            autoDetectedLanguage: settings.language == nil, modelDisplayName: modelDisplayName, savedURL: selected.url,
            exporter: { services.exporter },
            cleanupStyle: styling.defaultStyle,
            cleanupOptions: StylingOptions(style: styling.defaultStyle, removeFillers: styling.removeFillers, autoPunctuate: styling.autoPunctuate),
            pasteboard: SystemPasteboard(), revealer: FinderRevealer())
    }

    private var queueBody: some View {
        VStack(spacing: 0) {
            if model.needsModel {
                ModelRequiredBanner {
                    navigation.page = .settings
                    navigation.settingsTab = .models
                }
            }
            ScrollView {
                Group {
                    if model.items.isEmpty {
                        DropZoneView(isFileImporterPresented: requestFileImportBinding)
                    } else {
                        QueueListView(model: model)
                    }
                }
                .padding(20)
            }
            FilesToolbar(model: model, settings: services.filesSettings)
        }
        .onDrop(of: [.fileURL], delegate: FilesDropDelegate(model: model))
        // Page-level, not `DropZoneView`-level: `DropZoneView` is replaced by `QueueListView` once
        // the queue is non-empty, so an overlay scoped to the empty state would give no feedback
        // when dropping more files onto an already-populated queue (design MW-06g applies either
        // way). `allowsHitTesting(false)` keeps it from stealing the drop itself.
        .overlay {
            if model.isDragOver { FilesDragOverOverlay(dragCount: model.dragCount) }
        }
    }

    /// Backs both the drop zone's "Choose Files…" button and File › Open (`Navigation.requestFileImport`)
    /// with the same presentation, so either entry point opens the same panel and resets the same flag.
    private var requestFileImportBinding: Binding<Bool> {
        Binding(get: { navigation.requestFileImport }, set: { navigation.requestFileImport = $0 })
    }

}

/// The live MW-06g overlay used while files are held over the Files page.
struct FilesDragOverOverlay: View {
    let dragCount: Int

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 11))
            Text("Release to add \(dragCount) \(dragCount == 1 ? "file" : "files")").font(.headline)
            Text("processed on this Mac").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.accentColor.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
        )
        .padding(8)
        .allowsHitTesting(false)
    }

}

private extension FilesPage {

    // MARK: Alerts (design MW-06c stop confirmation, 3e long-audio confirmation)

    private var alertIsPresented: Binding<Bool> {
        Binding(get: { model.confirmation != nil }, set: { isPresented in
            if !isPresented { model.cancelConfirmation() }
        })
    }

    private var alertTitle: String {
        switch model.confirmation {
        case .stop(let item, _): FilesViewModel.stopAlertTitle(for: item)
        case .longAudio(_, let hours): FilesViewModel.longAudioAlertTitle(hours: hours)
        case nil: ""
        }
    }

    private func alertMessage(_ confirmation: FilesViewModel.Confirmation) -> String {
        switch confirmation {
        case .stop(_, let progress): FilesViewModel.stopAlertMessage(progress: progress)
        case .longAudio(_, let hours): FilesViewModel.longAudioAlertMessage(hours: hours)
        }
    }

    @ViewBuilder
    private func alertButtons(_ confirmation: FilesViewModel.Confirmation) -> some View {
        switch confirmation {
        case .stop:
            Button("Keep going", role: .cancel) { model.cancelConfirmation() }
            Button("Stop", role: .destructive) { Task { await model.confirmStop() } }
        case .longAudio:
            Button("Cancel", role: .cancel) { model.cancelConfirmation() }
            Button("Transcribe") { Task { await model.confirmLongAudio() } }
        }
    }
}
