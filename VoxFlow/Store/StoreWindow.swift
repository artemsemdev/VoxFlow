import SwiftUI
import VoxFlowDictation

struct StoreWindow: View {
    @Environment(StoreServices.self) private var services
    @State private var page = "Dictation"
    @State private var importing = false

    var body: some View {
        NavigationSplitView {
            StoreSidebar(page: $page)
                .navigationSplitViewColumnWidth(220)
        } detail: {
            Group {
                switch page {
                case "Files": StoreFilesPage(importing: $importing, showModels: { page = "Models" })
                case "Models": ModelsSettingsView(model: services.models, footerText: StoreServices.modelsFooter)
                default: StoreDictationView(showModels: { page = "Models" })
                }
            }
            .navigationTitle(page)
        }
        .frame(minWidth: 1000, minHeight: 650)
        .task { await services.observeDictation() }
        .onOpenURL { url in
            page = "Files"
            Task { await services.importFiles([url]) }
        }
        .toolbar {
            Button("Open Files…", systemImage: "folder") { page = "Files"; importing = true }
                .keyboardShortcut("o", modifiers: .command)
        }
    }
}

struct StoreSidebar: View {
    @Binding var page: String
    var body: some View {
        VStack(spacing: 6) {
            row("Dictation", icon: "mic")
            row("Files", icon: "doc.text")
            row("Models", icon: "arrow.down.circle")
            Spacer()
            SidebarFooter()
        }
        .padding(12)
    }
    private func row(_ title: String, icon: String) -> some View {
        Button { page = title } label: {
            Label(title, systemImage: icon).foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(page == title ? Color.accentColor.opacity(0.15) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(page == title ? [.isSelected] : [])
    }

}

struct StoreDictationView: View {
    @Environment(StoreServices.self) private var services
    let showModels: () -> Void
    var body: some View {
        StoreDictationContent(draft: services.draft, status: services.dictationStatus,
            recording: services.state.hasUnfinishedCapture, processing: services.state.isProcessing,
            requestingMicrophone: services.isRequestingMicrophone,
            start: { Task { await services.startDictation() } },
            stop: { Task { await services.dictation.pushToTalkReleased() } }, showModels: showModels)
    }
}

struct StoreDictationContent: View {
    @Bindable var draft: StoreDraft
    let status: String
    var recording = false
    var processing = false
    var requestingMicrophone = false
    let start: () -> Void
    let stop: () -> Void
    let showModels: () -> Void
    @State private var copied = false
    @State private var exportError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your voice. Your words.").font(.largeTitle.bold())
                Text("Dictate into VoxFlow, then copy or save your text. Speech stays on this Mac.")
                    .font(.title3).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                if recording {
                    Button("Stop recording", systemImage: "stop.fill", action: stop)
                    .disabled(processing)
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Start dictation", systemImage: "mic.fill", action: start)
                    .disabled(requestingMicrophone)
                    .buttonStyle(.borderedProminent)
                }
                Text(status).foregroundStyle(.secondary)
                Spacer()
                Button("Speech models", action: showModels)
            }
            TextEditor(text: $draft.text)
                .font(.system(size: 18))
                .padding(12)
                .scrollContentBackground(.hidden)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
                .disabled(recording)
                .accessibilityLabel("Dictation draft")
                .onChange(of: draft.text) { _, _ in draft.save(); copied = false }
            if let error = exportError ?? draft.saveError {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Text(draft.saveError == nil ? "Draft saved locally · Recording stops after 10 seconds of silence" : "Draft could not be saved · Copy your text before quitting")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save as…") {
                    if case .failed(let error) = SavePanel.save(baseName: "Dictation", format: .txt, contents: draft.text) {
                        exportError = error.localizedDescription
                    } else { exportError = nil }
                }
                .disabled(draft.text.isEmpty)
                Button(copied ? "Copied" : "Copy text", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    SystemPasteboard().setString(draft.text); copied = true
                }
                .buttonStyle(.borderedProminent).disabled(draft.text.isEmpty)
            }
        }
        .padding(28)
    }
}
