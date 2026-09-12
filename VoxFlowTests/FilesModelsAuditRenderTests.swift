import AppKit
import SwiftUI
import Testing
import VoxFlowCore
import VoxFlowModels
import VoxFlowTestSupport
@testable import VoxFlow

/// Fresh production component captures for the remaining Files / Models canvas audit (#141).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_RENDER"] != nil))
@MainActor
struct FilesModelsAuditRenderTests {
    @Test("renders every Models row state with the shipping model names and sizes")
    func modelRows() async throws {
        let temporary = TemporaryDirectory()
        let store = ModelStore(directory: temporary.file("Models"), catalog: ModelCatalog.all,
                               downloader: FakeModelDownloader(), freeSpace: FakeFreeSpace(available: 10_000_000_000),
                               settings: InMemoryKeyValueStore())
        let model = ModelsViewModel(store: store)
        await model.refresh()
        let descriptor = try #require(ModelCatalog.model(id: "whisper-small"))
        let variants: [(String, ModelState)] = [
            ("not-installed", .notInstalled), ("installed", .installed),
            ("downloading", .downloading(bytesWritten: 200_000_000, total: descriptor.sizeInBytes)),
            ("paused", .paused(bytesWritten: 200_000_000, total: descriptor.sizeInBytes)),
            ("verifying", .verifying)
        ]
        for (name, state) in variants {
            for dark in [false, true] {
                let row = ModelsViewModel.Row(model: descriptor, state: state, isDefault: false)
                try await captureSettled(ModelsSettingsView(model: model).rowView(row), name: "Models-141-\(name)",
                            size: NSSize(width: 640, height: 130), dark: dark)
            }
        }
        for dark in [false, true] {
            let row = ModelsViewModel.Row(model: descriptor, state: .installed, isDefault: true)
            try await captureSettled(ModelsSettingsView(model: model).rowView(row), name: "Models-141-default-installed",
                        size: NSSize(width: 640, height: 130), dark: dark)
        }
        withExtendedLifetime(temporary) {}
    }

    @Test("renders Files queue controls in every output format and missing-model state")
    func filesControls() async throws {
        let fixture = try await FilesViewModelTests.Harness(preSeed: [FilesViewModelTests.a, FilesViewModelTests.a])
        await fixture.settle()
        for format in OutputFormat.allCases {
            fixture.settings.outputFormat = format
            try await captureSettled(VStack(spacing: 0) {
                QueueListView(model: fixture.viewModel).padding(20)
                Spacer()
                FilesToolbar(model: fixture.viewModel, settings: fixture.settings)
            }, name: "Files-141-toolbar-\(format.rawValue)", size: NSSize(width: 900, height: 400))
        }
        let noModel = try await FilesViewModelTests.Harness(installedModel: false)
        await noModel.settle()
        try await captureSettled(VStack(spacing: 0) {
            ModelRequiredBanner {}
            DropZoneView(isFileImporterPresented: .constant(false)).padding(20)
            Spacer()
            FilesToolbar(model: noModel.viewModel, settings: noModel.settings)
        }, name: "Files-141-model-required", size: NSSize(width: 900, height: 500))
        withExtendedLifetime([fixture.dir, noModel.dir]) {}
    }

    @Test("renders corrupt input and the shipped app icon")
    func corruptInputAndIcon() async throws {
        let fixture = try await FilesViewModelTests.Harness()
        await fixture.transcriber.script(FilesViewModelTests.a, .failure(.decodeFailed("corrupt")))
        await fixture.viewModel.addFiles([FilesViewModelTests.a])
        await fixture.viewModel.transcribeAll()
        await fixture.settle()
        try await captureSettled(QueueListView(model: fixture.viewModel), name: "Files-141-corrupt",
                    size: NSSize(width: 700, height: 200))
        let iconURL = try #require(Bundle.main.url(forResource: "AppIcon", withExtension: "icns"))
        let icon = try #require(NSImage(contentsOf: iconURL))
        try await captureSettled(Image(nsImage: icon).resizable().frame(width: 256, height: 256),
                    name: "AppIcon-141-shipped", size: NSSize(width: 280, height: 280))
        withExtendedLifetime(fixture.dir) {}
    }

    @Test("renders result formats, searched text and export failure using the production result view")
    func fileResults() async throws {
        let fixture = ResultViewModelTests.makeVM(modelDisplayName: "Whisper large-v3-turbo")
        for format in OutputFormat.allCases {
            fixture.format = format
            try await captureSettled(TranscriptResultView(resultModel: fixture, onBack: {}),
                        name: "Files-141-result-\(format.rawValue)", size: NSSize(width: 900, height: 600))
        }
        fixture.searchText = "attention"
        try await captureSettled(TranscriptResultView(resultModel: fixture, onBack: {}),
                    name: "Files-141-result-search", size: NSSize(width: 900, height: 600))
        fixture.searchText = "missing word"
        try await captureSettled(TranscriptResultView(resultModel: fixture, onBack: {}),
                    name: "Files-141-result-no-matches", size: NSSize(width: 900, height: 600))
        fixture.report(error: CocoaError(.fileWriteNoPermission))
        try await captureSettled(TranscriptResultView(resultModel: fixture, onBack: {}),
                    name: "Files-141-result-export-failed", size: NSSize(width: 900, height: 600))
    }

    @Test("captures all Files and Models alerts through their production presenters")
    func alerts() async throws {
        let fixture = try await FilesViewModelTests.Harness(preSeed: [FilesViewModelTests.a])
        await fixture.settle()
        let item = try #require(fixture.viewModel.items.first)
        let confirmations: [(String, FilesViewModel.Confirmation)] = [
            ("Files-141-stop", .stop(item, progress: 0.72)),
            ("Files-141-long-audio", .longAudio(urls: [FilesViewModelTests.a], hours: 5))
        ]
        for (name, confirmation) in confirmations {
            let host = NativeRenderHost(Color.clear.modifier(FilesAlerts(model: fixture.viewModel)),
                                        size: NSSize(width: 900, height: 600))
            await host.prepareForAlert()
            fixture.viewModel.confirmation = confirmation
            try await host.captureAlert(to: output(name))
            fixture.viewModel.cancelConfirmation()
            try await host.closeAlert()
        }
        let small = try #require(ModelCatalog.model(id: "whisper-small"))
        let large = try #require(ModelCatalog.model(id: "whisper-large-v3-turbo"))
        let alerts: [(String, ModelsViewModel.Alert)] = [
            ("Models-141-remove", .removeModel(small, keeps: large.displayName)),
            ("Models-141-cannot-remove", .cannotRemoveOnlyModel(large)),
            ("Models-141-disk", .insufficientSpace(large, required: large.sizeInBytes, available: 400_000_000)),
            ("Models-141-download-failed", .downloadFailed(small, reason: "The server answered 503.")),
            ("Models-141-offline", .offline(small, bytesWritten: 200_000_000, total: small.sizeInBytes, dictationKeepsWorking: true)),
            ("Models-141-offline-no-model", .offline(small, bytesWritten: 200_000_000, total: small.sizeInBytes, dictationKeepsWorking: false))
        ]
        for (name, alert) in alerts {
            let models = ModelsViewModel(store: fixture.store)
            await models.refresh()
            let host = NativeRenderHost(ModelsSettingsView(model: models), size: NSSize(width: 900, height: 600))
            await host.prepareForAlert()
            models.alert = alert
            try await host.captureAlert(to: output(name))
            models.dismissAlert()
            try await host.closeAlert()
        }
        withExtendedLifetime(fixture.dir) {}
    }

    private func captureSettled(_ view: some View, name: String, size: NSSize, dark: Bool = false) async throws {
        let host = NativeRenderHost(view, size: size, dark: dark)
        // Let SwiftUI reconcile each state and finish native layout on the run loop.
        // Await teardown too, so the next fixture cannot inherit an outgoing transaction.
        try await host.captureSettled(to: output("\(name)-\(dark ? "dark" : "light")"))
    }

    private func output(_ name: String) throws -> URL {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".superpowers/design/renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(name).png")
    }
}
