import SwiftUI
import UniformTypeIdentifiers
import VoxFlowCore
import VoxFlowFiles

/// The Files page (design 1c Files, MW-06): drop zone/queue + toolbar, replaced by the transcript
/// result view (design 2f) when a row is opened — not a sheet (controller ruling 6).
struct FilesPage: View {
    @Environment(Navigation.self) private var navigation
    @State private var model: FilesViewModel
    @State private var isFileImporterPresented = false

    init() {
        let services = AppServices.shared
        _model = State(wrappedValue: FilesViewModel(
            queue: services.queue, settings: services.filesSettings, modelStore: services.modelStore,
            durations: services.durations, exporter: { services.exporter }))
    }

    var body: some View {
        Group {
            if let selected = model.selected {
                TranscriptResultView(result: selected, settings: AppServices.shared.filesSettings, onBack: model.closeResult)
            } else {
                queueBody
            }
        }
        .navigationTitle("Files")
        .task { await model.refreshModelState() }
        .alert(alertTitle, isPresented: alertIsPresented, presenting: model.confirmation) { confirmation in
            alertButtons(confirmation)
        } message: { confirmation in
            Text(alertMessage(confirmation))
        }
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
                        DropZoneView(model: model, isFileImporterPresented: $isFileImporterPresented)
                    } else {
                        QueueListView(model: model)
                    }
                }
                .padding(20)
            }
            FilesToolbar(model: model, settings: AppServices.shared.filesSettings)
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.addFiles(urls) }
            return true
        } isTargeted: { targeted in
            model.isDragOver = targeted
        }
        .fileImporter(isPresented: $isFileImporterPresented, allowedContentTypes: [.audio, .movie], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { await model.addFiles(urls) }
            }
        }
    }

    // MARK: Alerts (design MW-06c stop confirmation, 3e long-audio confirmation)

    private var alertIsPresented: Binding<Bool> {
        Binding(get: { model.confirmation != nil }, set: { isPresented in
            if !isPresented { model.cancelConfirmation() }
        })
    }

    private var alertTitle: String {
        switch model.confirmation {
        case .stop(let item, _): "Stop transcribing “\(item.url.lastPathComponent)”?"
        case .longAudio(_, let hours): "Transcribe \(String(format: "%.1f", hours)) h of audio?"
        case nil: ""
        }
    }

    private func alertMessage(_ confirmation: FilesViewModel.Confirmation) -> String {
        switch confirmation {
        case .stop(_, let progress):
            "It’s \(Int((progress * 100).rounded()))% done. The partial transcript will be discarded and the file stays in the queue."
        case .longAudio(_, let hours):
            "About \(FilesViewModel.estimatedMinutes(forHours: hours)) min on this Mac."
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
