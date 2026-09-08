import SwiftUI
import UniformTypeIdentifiers
import VoxFlowCore
import VoxFlowFiles

/// The Files page (design 1c Files, MW-06): drop zone/queue + toolbar, replaced by the transcript
/// result view (design 2f) when a row is opened — not a sheet (controller ruling 6).
struct FilesPage: View {
    @Environment(Navigation.self) private var navigation
    @State private var model: FilesViewModel

    init() {
        let services = AppServices.shared
        _model = State(wrappedValue: FilesViewModel(
            queue: services.queue, settings: services.filesSettings, modelStore: services.modelStore,
            durations: services.durations, exports: services.exports))
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
                        DropZoneView(isFileImporterPresented: requestFileImportBinding)
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
        // Page-level, not `DropZoneView`-level: `DropZoneView` is replaced by `QueueListView` once
        // the queue is non-empty, so an overlay scoped to the empty state would give no feedback
        // when dropping more files onto an already-populated queue (design MW-06g applies either
        // way). `allowsHitTesting(false)` keeps it from stealing the drop itself.
        .overlay {
            if model.isDragOver { dragOverOverlay }
        }
        .fileImporter(isPresented: requestFileImportBinding, allowedContentTypes: [.audio, .movie], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { await model.addFiles(urls) }
            }
            navigation.requestFileImport = false
        }
    }

    /// Backs both the drop zone's "Choose Files…" button and File › Open (`Navigation.requestFileImport`)
    /// with the same presentation, so either entry point opens the same panel and resets the same flag.
    private var requestFileImportBinding: Binding<Bool> {
        Binding(get: { navigation.requestFileImport }, set: { navigation.requestFileImport = $0 })
    }

    private var dragOverOverlay: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(Color.accentColor)
            Text("Release to add files").font(.headline)
            Text("Processed on this Mac").font(.caption).foregroundStyle(.secondary)
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
