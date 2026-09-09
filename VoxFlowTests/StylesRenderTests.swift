import AppKit
import CryptoKit
import Foundation
import SwiftUI
import Testing
import VoxFlowCore
import VoxFlowStorage
import VoxFlowTestSupport
@testable import VoxFlow

private struct InsecureStylesKeyProvider: HistoryKeyProviding {
    func historyKey() throws -> HistoryKey { HistoryKey(key: .init(size: .bits256), isNewlyCreated: true) }
}

/// Design-fidelity renders (Task 5) — gated behind `VOXFLOW_RENDER`, same convention as
/// `DictionaryRenderTests`/`SnippetsRenderTests`. Run with
/// `TEST_RUNNER_VOXFLOW_RENDER=1 xcodebuild … -only-testing:VoxFlowTests/StylesRenderTests`, then
/// compare the PNGs in `.superpowers/design/renders/` against `canvas.pdf` page 8–9 (MW-05a "Add app
/// override") and the brief's MW-05 copy (no dedicated MW-05 canvas mock exists — the intro/"You
/// said:"/cards/overrides layout follows the Dictionary/History pages' look per the task brief).
///
/// Known `ImageRenderer` limitation (see `DictionaryRenderTests`'s doc comment for the first
/// writeup): `Toggle`/`Picker`/`Menu` rasterize as a plain yellow "unavailable cursor" glyph instead
/// of their real appearance. So in these PNGs: the two bottom toggles and the override-row/sheet
/// style pickers show that glyph — everything else is representative. Verify those by running the
/// live app instead.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_RENDER"] != nil))
@MainActor
struct StylesRenderTests {
    private struct Bundle {
        let vm: StylesViewModel
        let content: ContentService
        let dir: TemporaryDirectory
    }

    private func makeBundle(apps: FakeInstalledAppsProvider = FakeInstalledAppsProvider()) -> Bundle {
        let dir = TemporaryDirectory()
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        let styling = StylingSettings(store: InMemoryKeyValueStore())
        let service = HistoryService(url: dir.file("voxflow.sqlite"), settings: settings, keyProvider: { InsecureStylesKeyProvider() },
                                     clock: SystemMonotonicClock())
        let content = ContentService(history: service)
        let vm = StylesViewModel(content: content, stylingSettings: styling, installedApps: apps)
        return Bundle(vm: vm, content: content, dir: dir)
    }

    @Test("renders Styles states for design-fidelity comparison")
    func render() async throws {
        let directory = Self.rendersDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // 1. MW-05 — default page, Casual selected, no overrides yet.
        let defaultBundle = makeBundle()
        await defaultBundle.vm.load()
        try Self.render(StylesRenderPreview(viewModel: defaultBundle.vm), name: "1-default", directory: directory)

        // 2. MW-05 — Formal selected, two per-app overrides.
        let overridesBundle = makeBundle(apps: FakeInstalledAppsProvider(apps: [
            ("com.linear", "Linear"), ("com.tinyspeck.slackmacgap", "Slack"), ("com.google.chrome", "Google Docs"),
        ]))
        await overridesBundle.vm.load()
        overridesBundle.vm.defaultStyle = .formal
        await overridesBundle.vm.presentAddApp()
        overridesBundle.vm.selectApp(bundleID: "com.linear", name: "Linear")
        overridesBundle.vm.addAppSheet?.style = .veryCasual
        await overridesBundle.vm.addOverride()
        await overridesBundle.vm.presentAddApp()
        overridesBundle.vm.selectApp(bundleID: "com.google.chrome", name: "Google Docs")
        overridesBundle.vm.addAppSheet?.style = .verbatim
        await overridesBundle.vm.addOverride()
        try Self.render(StylesRenderPreview(viewModel: overridesBundle.vm), name: "2-overrides", directory: directory)

        // 3. MW-05a — "Add app override" sheet, Linear selected (canvas page 8's exact sample);
        // "Google Docs" carries a `hostAppName` ("Chrome") to exercise the browser-hosted-app hint
        // (design must-fix) the same way the canvas's own "Google Docs … Chrome" row does.
        let addAppBundle = makeBundle(apps: FakeInstalledAppsProvider(apps: [
            InstalledApp(bundleID: "com.google.chrome", name: "Google Docs", hostAppName: "Chrome"),
            InstalledApp(bundleID: "com.linear", name: "Linear"),
            InstalledApp(bundleID: "com.notion", name: "Notion"),
            InstalledApp(bundleID: "com.discord", name: "Discord"),
        ]))
        await addAppBundle.vm.load()
        await addAppBundle.vm.presentAddApp()
        addAppBundle.vm.selectApp(bundleID: "com.linear", name: "Linear")
        try Self.render(AddAppOverrideSheet(viewModel: addAppBundle.vm), name: "3-sheet-add-app", directory: directory)

        // 4. MW-05a app-list rows on their own (design must-fix), outside the sheet's live
        // `ScrollView` — that renders blank under `ImageRenderer` (case 3 above), so this is the
        // only render that actually shows the icon + trailing hint (a browser-hosted "Google Docs
        // … Chrome" row and a native-app row whose hint is its bundle id).
        let rowsPreview = VStack(spacing: 0) {
            AppListRow(app: InstalledApp(bundleID: "com.google.chrome", name: "Google Docs", hostAppName: "Chrome"), isSelected: false) {}
            Divider()
            AppListRow(app: InstalledApp(bundleID: "com.company.linear", name: "Linear"), isSelected: true) {}
        }
        .frame(width: 320)
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.secondary.opacity(0.2)))
        try Self.render(rowsPreview.padding(20), name: "4-app-list-rows", directory: directory)

        withExtendedLifetime([defaultBundle.dir, overridesBundle.dir, addAppBundle.dir]) {}
    }

    @MainActor
    private static func render(_ view: some View, name: String, directory: URL) throws {
        let renderer = ImageRenderer(content: view.frame(width: 900, height: 900).background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 2
        guard let image = renderer.nsImage else {
            Issue.record("Failed to render \(name)")
            return
        }
        try writePNG(image, to: directory.appendingPathComponent("Styles-\(name).png"))
    }

    private static func rendersDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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

/// Renders `StylesPageBody`'s content sharing every content-bearing subview with production
/// (`StylesIntro`, `StylesSaidBlock`, `StyleCardView`, `OverridesCard`, `StylesToggles` — review M6:
/// the intro/"You said:"/toggles used to be hand-retyped here, which could drift silently from a
/// copy change in production) — same reasoning as `DictionaryRenderPreview`. No live `ScrollView`
/// (blank under `ImageRenderer`).
private struct StylesRenderPreview: View {
    let viewModel: StylesViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StylesIntro()
            StylesSaidBlock()
            HStack(alignment: .top, spacing: 16) {
                ForEach(StylesViewModel.cards, id: \.style) { card in
                    StyleCardView(card: card, isSelected: viewModel.defaultStyle == card.style) {}
                }
            }
            OverridesCard(viewModel: viewModel)
            StylesToggles(viewModel: viewModel)
        }
        .padding(20)
        .frame(width: 900, height: 900)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
