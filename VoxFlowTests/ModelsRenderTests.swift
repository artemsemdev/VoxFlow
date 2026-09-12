import AppKit
import Foundation
import Testing
import VoxFlowCore
import VoxFlowModels
import VoxFlowTestSupport
@testable import VoxFlow

/// Native production-body evidence for issue #141 / design ST-03.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_RENDER"] != nil))
@MainActor
struct ModelsRenderTests {
    @Test("renders the production Models page with the shipping catalog")
    func renderCatalog() async throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".superpowers/design/renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = TemporaryDirectory()
        let store = ModelStore(directory: temporary.file("Models"), catalog: ModelCatalog.all,
                               downloader: FakeModelDownloader(), freeSpace: FakeFreeSpace(available: 10_000_000_000),
                               settings: InMemoryKeyValueStore())
        let model = ModelsViewModel(store: store)
        await model.refresh()

        let host = NativeRenderHost(ModelsSettingsView(model: model), size: NSSize(width: 900, height: 600))
        defer { host.close() }
        try host.capture(to: directory.appendingPathComponent("Models-141-catalog.png"))
        withExtendedLifetime(temporary) {}
    }
}
