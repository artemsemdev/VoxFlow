import AppKit
import CryptoKit
import Foundation
import SwiftUI
import Testing
import VoxFlowCore
import VoxFlowStorage
import VoxFlowTestSupport
@testable import VoxFlow

private struct InsecureSnippetsKeyProvider: HistoryKeyProviding {
    func historyKey() throws -> HistoryKey { HistoryKey(key: .init(size: .bits256), isNewlyCreated: true) }
}

/// Design-fidelity renders (Task 5) — gated behind `VOXFLOW_RENDER`, same convention as
/// `DictionaryRenderTests`. Run with `TEST_RUNNER_VOXFLOW_RENDER=1 xcodebuild … -only-testing:VoxFlowTests/SnippetsRenderTests`
/// (the `TEST_RUNNER_` prefix is required, confirmed empirically — see `DictionaryRenderTests`'s doc
/// comment), then compare the PNGs in `.superpowers/design/renders/` against `canvas.pdf` page 4
/// (MW-04v trigger conflict), page 8 (MW-04a "New snippet"/"Add app override"), page 9 (MW-04e "No
/// snippets").
///
/// Known `ImageRenderer` limitation (see `DictionaryRenderTests`'s doc comment for the first
/// writeup): `Toggle`/`Picker`/`Menu` rasterize as a plain yellow "unavailable cursor" glyph instead
/// of their real appearance. So in these PNGs: the "Say 'snippet'..." switch and the "Only in"
/// checkbox/picker show that glyph — everything else is representative. Verify those by running the
/// live app instead.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_RENDER"] != nil))
@MainActor
struct SnippetsRenderTests {
    private struct Bundle {
        let vm: SnippetsViewModel
        let content: ContentService
        let dir: TemporaryDirectory
    }

    private func makeBundle(apps: FakeInstalledAppsProvider = FakeInstalledAppsProvider()) -> Bundle {
        let dir = TemporaryDirectory()
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        let styling = StylingSettings(store: InMemoryKeyValueStore())
        let service = HistoryService(directory: dir, settings: settings, keyProvider: { InsecureSnippetsKeyProvider() },
                                     clock: SystemMonotonicClock())
        let content = ContentService(history: service)
        let vm = SnippetsViewModel(content: content, stylingSettings: styling, installedApps: apps)
        return Bundle(vm: vm, content: content, dir: dir)
    }

    @Test("renders Snippets states for design-fidelity comparison")
    func render() async throws {
        let directory = Self.rendersDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // 1. MW-04 list — a few sample cards with varying uses/preview lengths.
        let listBundle = makeBundle()
        _ = try? await listBundle.content.snippets.insert(trigger: "/sig", body: "Kind regards,\nAnh")
        _ = try? await listBundle.content.snippets.insert(trigger: "/standup",
                                                           body: "Yesterday: cursor\nToday:\nBlockers: none")
        _ = try? await listBundle.content.snippets.insert(trigger: "/eta", body: "Thanks for the update — I'll follow up by end of day.")
        await listBundle.content.noteUses(text: "", snippets: Array(repeating: "/sig", count: 84) + Array(repeating: "/standup", count: 12))
        await listBundle.vm.load()
        try Self.render(SnippetsRenderPreview(viewModel: listBundle.vm), name: "1-list", directory: directory)

        // 2. MW-04e — no snippets.
        let emptyBundle = makeBundle()
        await emptyBundle.vm.load()
        try Self.render(SnippetsRenderPreview(viewModel: emptyBundle.vm), name: "2-empty", directory: directory)

        // 3. MW-04a — blank "New snippet" sheet.
        let addBundle = makeBundle()
        await addBundle.vm.load()
        await addBundle.vm.presentNew()
        try Self.render(NewSnippetSheet(viewModel: addBundle.vm), name: "3-sheet-new", directory: directory)

        // 4. MW-04v — trigger conflict ("/sig" already used by "Email signature"), Save disabled.
        let validationBundle = makeBundle()
        _ = try? await validationBundle.content.snippets.insert(trigger: "/sig", body: "Email signature\nSent from VoxFlow")
        await validationBundle.vm.load()
        await validationBundle.vm.presentNew()
        validationBundle.vm.sheet?.trigger = "/sig"
        try Self.render(NewSnippetSheet(viewModel: validationBundle.vm), name: "4-validation-duplicate", directory: directory)

        // 5. MW-04a — "Only in Slack" checked, with an Insert body.
        let onlyInBundle = makeBundle(apps: FakeInstalledAppsProvider(apps: [("com.tinyspeck.slackmacgap", "Slack")]))
        await onlyInBundle.vm.load()
        await onlyInBundle.vm.presentNew()
        onlyInBundle.vm.sheet?.trigger = "/standup"
        onlyInBundle.vm.sheet?.body = "Yesterday: cursor\nToday:\nBlockers: none"
        onlyInBundle.vm.setOnlyIn(true)
        try Self.render(NewSnippetSheet(viewModel: onlyInBundle.vm), name: "5-sheet-only-in", directory: directory)

        withExtendedLifetime([listBundle.dir, emptyBundle.dir, addBundle.dir, validationBundle.dir, onlyInBundle.dir]) {}
    }

    @MainActor
    private static func render(_ view: some View, name: String, directory: URL) throws {
        let renderer = ImageRenderer(content: view.frame(width: 900, height: 640).background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 2
        guard let image = renderer.nsImage else {
            Issue.record("Failed to render \(name)")
            return
        }
        try writePNG(image, to: directory.appendingPathComponent("Snippets-\(name).png"))
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

/// Renders `SnippetsPageBody`'s content sharing every content-bearing subview with production
/// (`SnippetsHeader`, `SnippetsGrid`, `SnippetsEmptyView`, `SnippetsSayPrefixRow` — review M6: the
/// header used to be hand-retyped here, which could drift silently from a copy change in
/// `SnippetsHeader`) — same reasoning as `DictionaryRenderPreview`. No live `ScrollView` (blank
/// under `ImageRenderer`).
private struct SnippetsRenderPreview: View {
    let viewModel: SnippetsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SnippetsHeader {}
            if viewModel.isEmpty {
                SnippetsEmptyView(viewModel: viewModel).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SnippetsGrid(viewModel: viewModel)
            }
            SnippetsSayPrefixRow(viewModel: viewModel)
        }
        .padding(20)
        .frame(width: 900, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
