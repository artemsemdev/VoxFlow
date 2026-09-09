import AppKit
import Foundation
import SwiftUI
import Testing
import VoxFlowCore
import VoxFlowStorage
import VoxFlowTestSupport
@testable import VoxFlow

/// Design-fidelity renders (Task 3 Step 3) — gated behind `VOXFLOW_RENDER` so normal test runs never
/// touch disk. Run with `VOXFLOW_RENDER=1 xcodebuild … -only-testing:VoxFlowTests/HistoryRenderTests`,
/// then compare the PNGs in `.superpowers/design/renders/` against `canvas.pdf` pages 9 (2e/2d) and 4
/// (MW-02n/T-01).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_RENDER"] != nil))
@MainActor
struct HistoryRenderTests {
    private struct Bundle {
        let vm: HistoryViewModel
        let service: HistoryService
        let settings: DictationSettings
        let clock: FakeClock
    }

    private func draft(_ text: String, raw: String? = nil, appName: String, style: String?, language: String?,
                       duration: TimeInterval, minutesAgo: Double) -> DictationDraft {
        DictationDraft(text: text, rawText: raw ?? text, appName: appName, style: style, language: language,
                       duration: duration, createdAt: Date().addingTimeInterval(-minutesAgo * 60))
    }

    private func makeBundle(keepHistory: Bool = true) -> Bundle {
        let dir = TemporaryDirectory()
        let clock = FakeClock()
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        settings.encryptHistory = true
        settings.retentionDays = 30
        settings.keepHistory = keepHistory
        let navigation = Navigation()
        let service = HistoryService(url: dir.file("voxflow.sqlite"), settings: settings,
                                     keyProvider: { InsecureHistoryKeyProvider() }, clock: clock)
        let vm = HistoryViewModel(service: service, settings: settings, navigation: navigation, clock: clock)
        return Bundle(vm: vm, service: service, settings: settings, clock: clock)
    }

    private func seed(_ bundle: Bundle) async {
        _ = await bundle.service.count()   // force the open to finish
        let store = bundle.service.store!
        _ = try! store.insert(draft("can we push the meeting to thursday afternoon I need the numbers from finance first",
                                    raw: "um so can we uh push the meeting to like thursday afternoon I mean I need the numbers from finance first",
                                    appName: "Slack", style: "Very casual", language: "en", duration: 9, minutesAgo: 14))
        _ = try! store.insert(draft("Hi Priya, attaching the signed NDA. Let me know if legal needs anything else.",
                                    appName: "Mail", style: "Formal", language: "en", duration: 12, minutesAgo: 2))
        _ = try! store.insert(draft("Ideas for the Q4 roadmap: batch transcription for the research team, a shared style library",
                                    appName: "Notes", style: "Casual", language: "en", duration: 18, minutesAgo: 60))
        _ = try! store.insert(draft("Refactor the audio buffer so the ring buffer is allocated once, then reused across takes",
                                    appName: "Xcode", style: "Verbatim", language: "en", duration: 15, minutesAgo: 180))
    }

    private struct RenderCase {
        let name: String
        var keepHistory = true
        var seeded = true
        let configure: @MainActor (Bundle) async -> Void
    }

    private static let cases: [RenderCase] = [
        RenderCase(name: "1-list") { bundle in await bundle.vm.load() },
        RenderCase(name: "2-expanded") { bundle in
            await bundle.vm.load()
            if let first = bundle.vm.records.first { bundle.vm.toggleExpanded(id: first.id) }
        },
        RenderCase(name: "3-no-dictations", seeded: false) { bundle in await bundle.vm.load() },
        RenderCase(name: "4-history-off", keepHistory: false) { bundle in await bundle.vm.load() },
        RenderCase(name: "5-no-results") { bundle in
            await bundle.vm.load()
            let sleepersBefore = bundle.clock.sleeperCount
            bundle.vm.query = "quarterly numbers"
            await bundle.clock.waitForSleepers(sleepersBefore + 1)
            await bundle.clock.advance(by: 0.15)
            for _ in 0..<2_000 where !bundle.vm.records.isEmpty { await Task.yield() }
        },
        RenderCase(name: "6-toast-undo") { bundle in
            await bundle.vm.load()
            if let first = bundle.vm.records.first { bundle.vm.delete(first) }
        },
    ]

    @Test("renders History states for design-fidelity comparison")
    func render() async throws {
        let directory = Self.rendersDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for testCase in Self.cases {
            let bundle = makeBundle(keepHistory: testCase.keepHistory)
            if testCase.seeded { await seed(bundle) }
            await testCase.configure(bundle)
            let vm = bundle.vm
            let renderer = ImageRenderer(content: HistoryRenderPreview(viewModel: vm).frame(width: 900, height: 600))
            renderer.scale = 2
            guard let image = renderer.nsImage else {
                Issue.record("Failed to render \(testCase.name)")
                continue
            }
            let url = directory.appendingPathComponent("History-\(testCase.name).png")
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

/// Renders `HistoryPageBody`'s content for `ImageRenderer`, sharing every content-bearing subview
/// with production (`HistorySearchChips`, `HistoryRowList`, `HistoryEmptyView`, `UndoToastView`, and
/// `HistoryViewModel.footerText`) — M3's concern was real re-implementation risk (rows, detail
/// wiring, empty-state copy silently drifting), and none of that is duplicated here.
///
/// Two pieces still can't be the production view verbatim, confirmed empirically (not assumed): a
/// live `TextField` renders as a solid colour-filled glyph under `ImageRenderer` with no real window
/// behind it, and a live `ScrollView` renders its content as entirely blank. Both are substituted
/// with static equivalents (`Text` for the field, a plain `VStack` via `HistoryRowList` with no
/// `ScrollView` wrapper) — layout-identical, just not interactive.
private struct HistoryRenderPreview: View {
    let viewModel: HistoryViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    Text(viewModel.query.isEmpty ? "Search your dictations" : viewModel.query)
                        .foregroundStyle(viewModel.query.isEmpty ? .secondary : .primary)
                    if !viewModel.query.isEmpty {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.secondary.opacity(0.25)))
                HistorySearchChips()
                Spacer(minLength: 0)
            }
            .padding(20)
            Group {
                if let emptyState = viewModel.emptyState {
                    HistoryEmptyView(state: emptyState, model: viewModel)
                } else {
                    HistoryRowList(viewModel: viewModel)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if viewModel.emptyState != .historyOff {
                Divider()
                Text(viewModel.footerText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay(alignment: .bottom) {
            if viewModel.toastVisible {
                UndoToastView(onUndo: viewModel.undo)
                    .padding(.bottom, 16)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Unencrypted-but-not-nil key provider so the render bundle's store opens without touching the
/// Keychain (no real secrets involved — this is only ever used for `ImageRenderer` snapshots).
private struct InsecureHistoryKeyProvider: HistoryKeyProviding {
    func historyKey() throws -> HistoryKey {
        HistoryKey(key: .init(size: .bits256), isNewlyCreated: true)
    }
}
