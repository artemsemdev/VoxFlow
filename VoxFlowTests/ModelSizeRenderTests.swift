import AppKit
import Foundation
import SwiftUI
import Testing
import VoxFlowCore
import VoxFlowDictation
import VoxFlowModels
import VoxFlowTestSupport
@testable import VoxFlow

/// Native evidence that both production call sites show the shared canvas model sizes.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_RENDER"] != nil))
@MainActor
struct ModelSizeRenderTests {
    @Test("renders Settings and Flow Bar with shared catalog size text")
    func renderCallSites() async throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".superpowers/design/renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let temporary = TemporaryDirectory()
        let store = ModelStore(directory: temporary.file("Models"), catalog: ModelCatalog.all,
                               downloader: FakeModelDownloader(), freeSpace: FakeFreeSpace(available: 10_000_000_000),
                               settings: InMemoryKeyValueStore())
        let models = ModelsViewModel(store: store)
        await models.refresh()
        let modelsHost = NativeRenderHost(ModelsSettingsView(model: models), size: NSSize(width: 900, height: 600))
        try modelsHost.capture(to: directory.appendingPathComponent("Models-142-shared-sizes.png"))
        modelsHost.close()

        let content = FlowBarContent.make(state: .modelNotInstalled(sizeBytes: 487_601_967), elapsed: 0, mode: .pushToTalk)
        let flowBar = ZStack {
            Color(red: 0xd9 / 255, green: 0xdb / 255, blue: 0xe0 / 255)
            FlowBarView(content: content, levels: [])
        }
        let flowHost = NativeRenderHost(flowBar, size: NSSize(width: 420, height: 80))
        try flowHost.capture(to: directory.appendingPathComponent("FlowBar-142-shared-size.png"))
        flowHost.close()
        withExtendedLifetime(temporary) {}
    }
}
