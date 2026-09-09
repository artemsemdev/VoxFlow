import AppKit
import CryptoKit
import SwiftUI
import Testing
import VoxFlowCore
import VoxFlowDictation
import VoxFlowModels
import VoxFlowStorage
import VoxFlowTestSupport
@testable import VoxFlow

/// Design-fidelity renders (Task 2 Step 4) — gated behind `VOXFLOW_RENDER` so normal test runs never
/// touch disk. Run with `VOXFLOW_RENDER=1 xcodebuild … -only-testing:VoxFlowTests/OnboardingRenderTests`,
/// then compare the PNGs in `.superpowers/design/renders/` against `canvas.pdf` pages 10–12.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_RENDER"] != nil))
@MainActor
struct OnboardingRenderTests {
    static func payload(_ seed: UInt8, count: Int) -> Data { Data((0..<count).map { UInt8(($0 &+ Int(seed)) % 256) }) }
    static let bigPayload = payload(1, count: 1_624_555_275 / 3_000)   // scaled down; only the byte count matters here
    static func descriptor(id: String, displayName: String, payload: Data, isDefault: Bool) -> ModelDescriptor {
        ModelDescriptor(id: id, displayName: displayName, role: .speech,
                        downloadURL: URL(string: "https://example.com/\(id).bin")!,
                        sizeInBytes: Int64(payload.count),
                        sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
                        languagesSummary: "99 languages · best accuracy on M-series", isDefault: isDefault)
    }
    static let big = descriptor(id: "whisper-large-v3-turbo", displayName: "Whisper large-v3-turbo", payload: bigPayload, isDefault: true)
    static let small = ModelDescriptor(id: "whisper-small", displayName: "Whisper small", role: .speech,
                                       downloadURL: URL(string: "https://example.com/small.bin")!,
                                       sizeInBytes: 487_601_967, sha256: "", languagesSummary: "99 languages · for 8 GB Macs", isDefault: false)
    static let catalog = [big, small]

    /// Everything one render case might need to drive: the view model plus its collaborators that
    /// aren't otherwise reachable through it (the downloader, to park a mid-download state; the
    /// dictation coordinator and clock, to drive a Try It capture through to `.inserted`).
    private struct Bundle {
        let vm: OnboardingViewModel
        let downloader: FakeModelDownloader
        let dictation: DictationCoordinator
        let clock: FakeClock
    }

    private func makeBundle(step: OnboardingStep, accessibility: Bool = true) -> Bundle {
        let settingsStore = InMemoryKeyValueStore()
        let dir = TemporaryDirectory()
        let downloader = FakeModelDownloader()
        let modelStore = ModelStore(directory: dir.url, catalog: Self.catalog, downloader: downloader,
                                    freeSpace: FakeFreeSpace(available: 10_000_000_000), settings: settingsStore)
        let models = ModelsViewModel(store: modelStore, catalog: Self.catalog)
        let dictationSettings = DictationSettings(store: settingsStore)
        let permissions = FakePermissions(microphone: .granted, requestResult: .granted, accessibility: accessibility)
        let navigation = Navigation()
        let historyStoreBox = HistoryStoreBox(try? DictationStore(inMemoryWith: nil))
        let historyWriter = HistoryWriter(storeBox: historyStoreBox, settings: dictationSettings.box, now: { Date() })
        let transcriber = FakeDictationTranscriber(result: DictationResult(
            text: "testing one two three four five this is voxflow running on my mac",
            rawText: "testing one two three four five this is voxflow running on my mac",
            segments: [], language: nil, duration: 0.6, lowConfidence: false))
        let clock = FakeClock()
        let controller = DictationController(config: FlowBarConfig(), microphone: FakeMicrophone(), transcriber: transcriber,
                                             inserter: FakeTextInserter(), clock: clock,
                                             preflight: { Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .loaded) },
                                             loadModel: {}, options: { TranscriptionOptions() },
                                             onSave: { result, appName in await historyWriter.save(result, appName: appName) },
                                             copyToClipboard: { _ in })
        let dictation = DictationCoordinator(controller: controller, settings: dictationSettings, permissions: permissions, navigation: navigation)
        dictation.start()
        let state = OnboardingState(store: settingsStore)
        state.step = step
        let vm = OnboardingViewModel(state: state, permissions: permissions, settings: dictationSettings, models: models,
                                     dictation: dictation, historyWriter: historyWriter, navigation: navigation, clock: clock)
        return Bundle(vm: vm, downloader: downloader, dictation: dictation, clock: clock)
    }

    private struct RenderCase {
        let name: String
        let step: OnboardingStep
        var accessibility = true
        let configure: @MainActor (Bundle) async -> Void
    }

    private static let cases: [RenderCase] = [
        RenderCase(name: "1-welcome", step: .welcome) { _ in },
        RenderCase(name: "2-permissions", step: .permissions) { bundle in await bundle.vm.requestMicrophone() },
        RenderCase(name: "2a-accessibility-denied", step: .permissions, accessibility: false) { bundle in
            await bundle.vm.requestMicrophone()
            bundle.vm.openAccessibilitySettings()
        },
        RenderCase(name: "3-hotkey", step: .hotkey) { _ in },
        RenderCase(name: "4-model", step: .model) { bundle in
            for _ in 0..<200 where bundle.vm.modelRow == nil { await Task.yield() }
        },
        RenderCase(name: "5-tryit", step: .tryIt) { _ in },
    ]

    @Test("renders every onboarding step for design-fidelity comparison")
    func render() async throws {
        let directory = Self.rendersDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for testCase in Self.cases {
            let bundle = makeBundle(step: testCase.step, accessibility: testCase.accessibility)
            await testCase.configure(bundle)
            let vm = bundle.vm
            let renderer = ImageRenderer(content: OnboardingContentView(viewModel: vm).frame(width: 700, height: 520))
            renderer.scale = 2
            guard let image = renderer.nsImage else {
                Issue.record("Failed to render \(testCase.name)")
                continue
            }
            let url = directory.appendingPathComponent("Onboarding-\(testCase.name).png")
            try Self.writePNG(image, to: url)
        }
    }

    private static func rendersDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // VoxFlowTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent(".superpowers/design/renders")
    }

    private static func writePNG(_ image: NSImage, to url: URL) throws {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            Issue.record("Failed to encode PNG for \(url.lastPathComponent)")
            return
        }
        try png.write(to: url)
    }
}
