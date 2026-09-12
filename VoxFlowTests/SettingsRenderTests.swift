import AppKit
import CryptoKit
import Foundation
import SwiftUI
import Testing
import VoxFlowCore
import VoxFlowDictation
import VoxFlowModels
import VoxFlowStorage
import VoxFlowTestSupport
@testable import VoxFlow

/// Design-fidelity renders (Task 4 Step 3/4, extended in Task 3 for General, and by phase 6's own
/// Task 4 for MCP — see `MCPRenderTests`, which now owns that tab) — gated behind `VOXFLOW_RENDER`
/// so normal test runs never touch disk. Run with
/// `TEST_RUNNER_VOXFLOW_RENDER=1 xcodebuild … -only-testing:VoxFlowTests/SettingsRenderTests`
/// (see `OnboardingRenderTests` for why the `TEST_RUNNER_` prefix is needed), then compare the PNGs
/// in `.superpowers/design/renders/` against `canvas.pdf` page 6 (ST-04n, ST-03v) and page 9
/// (ST-05d) — the Settings tabs themselves are interactive in the canvas HTML and weren't captured
/// on separate PDF pages.
/// Renders `HotkeysSettingsBody`/`AudioSettingsBody`/`PrivacySettingsBody`/`GeneralSettingsBody`
/// directly rather than the `ScrollView`-wrapped `…View`s: `ImageRenderer` doesn't reliably capture
/// `ScrollView` content (confirmed empirically — see the task report), the same
/// reason `HistoryPage` factors its content into `HistoryPageBody`. `Models-baseline` is a
/// same-style stand-in for `ModelsSettingsView` (ST-03, already shipped, out of this task's file
/// scope) so the grouped-form look has a fresh baseline to compare the new tabs against.
///
/// Known `ImageRenderer` limitation (confirmed empirically, not a real UI bug): AppKit-backed
/// controls that draw their own interaction chrome — `Toggle`, `Picker` (any style, including
/// `.menu`), `Menu` — rasterize as a plain yellow "unavailable cursor" glyph instead of their real
/// appearance, even disabled or hit-test-off. Labels, `Button`s (incl. custom-styled ones), and
/// `WaveformView` all render correctly. So in these PNGs: "Default mode", "Stop after silence",
/// "Delete history after", "Keep dictation history" and "Encrypt history at rest" show that glyph
/// where the picker/toggle would be — everything else (row titles/subtitles, the ST-04n banner, the
/// ST-05 header/stats, excluded-app chips, buttons) is representative. Verify Toggle/Picker
/// appearance by running the live app instead.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_RENDER"] != nil))
@MainActor
struct SettingsRenderTests {
    private struct FakeInputDeviceProvider: InputDeviceProviding {
        let name: String?
        func defaultInputName() -> String? { name }
    }

    private struct FakeInstalledApps: InstalledAppsProviding {
        let names: [String: String]
        func name(forBundleID bundleID: String) -> String? { names[bundleID] }
        @MainActor func pickApplication() async -> String? { nil }
    }

    private struct FakeHistoryKeyProvider: HistoryKeyProviding {
        func historyKey() throws -> HistoryKey { HistoryKey(key: SymmetricKey(size: .bits256), isNewlyCreated: true) }
    }

    /// Minimal `DictationCoordinator` — only its (flat, idle) `.levels` are read by `AudioViewModel`.
    private func makeCoordinator() -> DictationCoordinator {
        let controller = DictationController(config: FlowBarConfig(), microphone: FakeMicrophone(),
                                             transcriber: FakeDictationTranscriber(result: .empty), inserter: FakeTextInserter(),
                                             clock: FakeClock(), preflight: { Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .loaded) },
                                             loadModel: {}, options: { TranscriptionOptions() }, onSave: { _, _ in }, copyToClipboard: { _ in })
        return DictationCoordinator(controller: controller, settings: DictationSettings(store: InMemoryKeyValueStore()),
                                    permissions: FakePermissions(microphone: .granted, requestResult: .granted, accessibility: true),
                                    navigation: Navigation())
    }

    private func makePrivacyModel(dir: TemporaryDirectory, excluded: [String] = DictationSettings.defaultExcluded,
                                  secureEnclaveAvailable: Bool = true) -> PrivacyViewModel {
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        settings.excludedBundleIDs = excluded
        let service = HistoryService(directory: dir, settings: settings, keyProvider: { FakeHistoryKeyProvider() }, clock: FakeClock())
        let apps = FakeInstalledApps(names: ["com.1password.1password": "1Password", "com.apple.keychainaccess": "Keychain Access"])
        return PrivacyViewModel(settings: settings, history: service, apps: apps, secureEnclaveAvailable: { secureEnclaveAvailable })
    }

    @Test("renders Hotkeys/Audio/Privacy (+ Models baseline) for design-fidelity comparison")
    func render() async throws {
        let directory = Self.rendersDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Hotkeys (ST-02): default push-to-talk mode, then hands-free (footer text changes).
        let pushToTalkSettings = DictationSettings(store: InMemoryKeyValueStore())
        try Self.render(HotkeysSettingsBody(settings: pushToTalkSettings), name: "hotkeys-1-push-to-talk", to: directory)
        let handsFreeSettings = DictationSettings(store: InMemoryKeyValueStore())
        handsFreeSettings.hotkeyMode = .handsFree
        try Self.render(HotkeysSettingsBody(settings: handsFreeSettings), name: "hotkeys-2-hands-free", to: directory)

        // Audio (ST-04, ST-04n): a device present, then none (banner).
        let withDevice = AudioViewModel(devices: FakeInputDeviceProvider(name: "MacBook Pro Microphone"),
                                        settings: DictationSettings(store: InMemoryKeyValueStore()), dictation: makeCoordinator())
        try Self.render(AudioSettingsView(audio: withDevice), name: "audio-1-device", to: directory)
        let noDevice = AudioViewModel(devices: FakeInputDeviceProvider(name: nil),
                                      settings: DictationSettings(store: InMemoryKeyValueStore()), dictation: makeCoordinator())
        try Self.render(AudioSettingsView(audio: noDevice), name: "audio-2-no-device", to: directory)

        // Privacy (ST-05): the default excluded apps, plus one with an extra app + Keychain subtitle.
        let privacyDefault = makePrivacyModel(dir: TemporaryDirectory())
        try Self.render(PrivacySettingsBody(privacy: privacyDefault), name: "privacy-1-default", to: directory)
        let privacyKeychain = makePrivacyModel(dir: TemporaryDirectory(),
                                               excluded: DictationSettings.defaultExcluded + ["com.example.discord"], secureEnclaveAvailable: false)
        try Self.render(PrivacySettingsBody(privacy: privacyKeychain), name: "privacy-2-keychain-and-extra-app", to: directory)

        // General (ST-01): defaults straight out of `GeneralSettings`/`DictationSettings`.
        let generalSettings = GeneralSettings(store: InMemoryKeyValueStore())
        let generalVM = GeneralViewModel(settings: generalSettings, dictationSettings: DictationSettings(store: InMemoryKeyValueStore()),
                                         loginItem: FakeLoginItem(), appearanceApplier: FakeAppearanceApplying(),
                                         flowBarPositioning: FakeFlowBarPositioning())
        try Self.render(GeneralSettingsBody(general: generalVM), name: "general", to: directory)

        // MCP (ST-06, ST-06a, ST-06r) — Task 4 backs this with the real server; its design-fidelity
        // renders (enabled state, connected clients, the ST-06a panel, the ST-06r alert) now live in
        // the dedicated `MCPRenderTests`, since `MCPSettingsBody` needs a real
        // `MCPServerControlling`/`MCPClientStoreProviding` pair that doesn't belong in this file.

        // Models (ST-03, already shipped, out of this task's file scope) — a same-style stand-in
        // rendered alongside as the grouped-form baseline to compare the three new tabs against.
        let harness = ModelsViewModelTests.Harness()
        let modelsVM = harness.viewModel()
        await modelsVM.refresh()
        try Self.render(ModelsBaselinePreview(model: modelsVM), name: "Models-baseline", to: directory)
    }

    private static func render(_ view: some View, name: String, to directory: URL) throws {
        let host = NativeRenderHost(view, size: NSSize(width: 900, height: 600))
        defer { host.close() }
        try host.capture(to: directory.appendingPathComponent("Settings-\(name).png"))
    }

    private static func rendersDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // VoxFlowTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent(".superpowers/design/renders")
    }

}

/// A same-style stand-in for `ModelsSettingsView`'s grouped section/row look (ST-03) — `ModelsSettingsView`
/// itself is out of this task's file scope (and, like `HotkeysSettingsView` before its `…Body` split,
/// wraps its content directly in a `ScrollView`, which `ImageRenderer` can't capture), so this
/// reproduces just enough of its layout for a same-page visual baseline.
private struct ModelsBaselinePreview: View {
    let model: ModelsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            section(title: "Speech recognition", rows: model.speechRows)
            section(title: "Cleanup & styles", rows: model.styleRows)
            Text(model.footerText).font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: 640, alignment: .leading)
    }

    private func section(title: String, rows: [ModelsViewModel.Row]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.model.displayName).fontWeight(.medium)
                            Text(row.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if row.state == .installed {
                            Label("Installed", systemImage: "checkmark.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(.green)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    if index < rows.count - 1 { Divider().padding(.leading, 16) }
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

/// `HotkeysCopy` (design ST-02 footer) — pulled out of the render/UI tests above since it needs no
/// rendering at all, just the exact wording and mode-label mapping.
@Suite("HotkeysCopy")
struct HotkeysCopyTests {
    @Test("footer names the current default mode and matches the design copy verbatim")
    func footerMatchesDesignCopy() {
        #expect(HotkeysCopy.modeLabel(.pushToTalk) == "Push-to-talk")
        #expect(HotkeysCopy.modeLabel(.handsFree) == "Hands-free")
        #expect(HotkeysCopy.footer(mode: .pushToTalk) ==
               "Click any shortcut to record a new one. Default mode is currently Push-to-talk — change it in Tweaks or here.")
        #expect(HotkeysCopy.footer(mode: .handsFree) ==
               "Click any shortcut to record a new one. Default mode is currently Hands-free — change it in Tweaks or here.")
    }
}
