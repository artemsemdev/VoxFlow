import AppKit
import CryptoKit
import Foundation
import Testing
import VoxFlowCore
import VoxFlowModels
import VoxFlowTestSupport
@testable import VoxFlow

/// Native production-view evidence for the inline ST-03v checksum failure row.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_RENDER"] != nil))
@MainActor
struct ModelsErrorRenderTests {
    @Test("renders the inline checksum failure in light and dark appearances")
    func renderChecksumFailure() async throws {
        let correct = Data(repeating: 1, count: 100_000)
        let wrong = Data(repeating: 2, count: correct.count)
        let descriptor = ModelDescriptor(
            id: "whisper-small", displayName: "Whisper small", role: .speech,
            downloadURL: URL(string: "https://example.com/ggml-small.bin")!,
            sizeInBytes: Int64(correct.count),
            sha256: SHA256.hash(data: correct).map { String(format: "%02x", $0) }.joined(),
            languagesSummary: "99 languages · for 8 GB Macs", isDefault: true)
        let temporary = TemporaryDirectory()
        let downloader = FakeModelDownloader()
        await downloader.serve(wrong, at: descriptor.downloadURL)
        let store = ModelStore(directory: temporary.file("Models"), catalog: [descriptor], downloader: downloader,
                               freeSpace: FakeFreeSpace(available: 10_000_000_000), settings: InMemoryKeyValueStore())
        let model = ModelsViewModel(store: store, catalog: [descriptor])
        await model.refresh()
        await model.download(descriptor)
        #expect(model.speechRows.first?.failureReason == ModelsViewModel.checksumFailureMessage)

        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".superpowers/design/renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, dark) in [("light", false), ("dark", true)] {
            let host = NativeRenderHost(ModelsSettingsView(model: model), size: NSSize(width: 900, height: 420), dark: dark)
            defer { host.close() }
            try host.capture(to: directory.appendingPathComponent("Models-141-checksum-\(name).png"))
        }
        withExtendedLifetime(temporary) {}
    }
}
