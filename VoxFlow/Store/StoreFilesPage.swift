import SwiftUI
import UniformTypeIdentifiers
import VoxFlowCore
import VoxFlowModels

/// Store-specific wiring around the shared queue, transcript and export views.
struct StoreFilesPage: View {
    @Environment(StoreServices.self) private var services
    @Binding var importing: Bool
    let showModels: () -> Void
    @State private var result: ResultViewModel?

    var body: some View {
        Group {
            if let result {
                TranscriptResultView(resultModel: result, onBack: services.files.closeResult)
            } else {
                VStack(spacing: 0) {
                    if services.files.needsModel { ModelRequiredBanner(onDownload: showModels) }
                    ScrollView {
                        Group {
                            if services.files.items.isEmpty {
                                DropZoneView(isFileImporterPresented: $importing)
                            } else { QueueListView(model: services.files) }
                        }.padding(20)
                    }
                    FilesToolbar(model: services.files, settings: services.settings)
                }
                .onDrop(of: [.fileURL], delegate: FilesDropDelegate(model: services.files, importFiles: services.importFiles))
            }
        }
        .modifier(FilesAlerts(model: services.files))
        .task { await services.files.refreshModelState() }
        .onChange(of: services.files.selected?.item.id, initial: true) { _, _ in
            result?.cancelCleanup()
            guard let selected = services.files.selected else { result = nil; return }
            let settings = services.settings
            result = ResultViewModel(document: selected.document, format: settings.outputFormat,
                timestamps: settings.timestamps, autoDetectedLanguage: settings.language == nil,
                modelDisplayName: ModelCatalog.model(id: selected.document.modelID)?.displayName ?? selected.document.modelID,
                savedURL: selected.url, exporter: settings.makeExporter,
                cleanupStyle: .formal, cleanupOptions: StylingOptions(style: .formal, removeFillers: true, autoPunctuate: true),
                pasteboard: SystemPasteboard(), revealer: FinderRevealer())
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .movie], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                services.files.closeResult()
                Task { await services.importFiles(urls) }
            }
        }
    }
}
