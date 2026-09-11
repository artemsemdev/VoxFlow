import AppKit
import Foundation
import SwiftUI
import Testing
import VoxFlowCore
import VoxFlowStorage
import VoxFlowTestSupport
@testable import VoxFlow

/// Design-fidelity renders (Task 3 Step 3) — gated behind `VOXFLOW_RENDER` so normal test runs never
/// touch disk. Run with `TEST_RUNNER_VOXFLOW_RENDER=1 xcodebuild … -only-testing:VoxFlowTests/HistoryRenderTests`,
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
        let vm = HistoryViewModel(service: service, settings: settings, navigation: navigation, clock: clock,
                                  initialDateRange: .thisWeek)
        return Bundle(vm: vm, service: service, settings: settings, clock: clock)
    }

    private func seed(_ bundle: Bundle) async {
        _ = await bundle.service.count()   // force the open to finish
        let store = bundle.service.store!
        _ = try! store.insert(draft("can we push the meeting to thursday afternoon I need the numbers from finance first",
                                    raw: "um so can we uh push the meeting to like thursday afternoon I mean I need the numbers from finance first",
                                    appName: "Slack", style: "veryCasual", language: "en", duration: 9, minutesAgo: 14))
        _ = try! store.insert(draft("Hi Priya, attaching the signed NDA. Let me know if legal needs anything else.",
                                    appName: "Mail", style: "formal", language: "en", duration: 12, minutesAgo: 2))
        _ = try! store.insert(draft("Ideas for the Q4 roadmap: batch transcription for the research team, a shared style library",
                                    appName: "Notes", style: "casual", language: "en", duration: 18, minutesAgo: 60))
        _ = try! store.insert(draft("Refactor the audio buffer so the ring buffer is allocated once, then reused across takes",
                                    appName: "Xcode", style: "verbatim", language: "en", duration: 15, minutesAgo: 180))
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
        RenderCase(name: "7-filtered-app") { bundle in
            await bundle.vm.load()
            bundle.vm.selectedApp = "Mail"
            bundle.vm.dateRange = .today
        },
        RenderCase(name: "8-filters-no-results") { bundle in
            await bundle.vm.load()
            bundle.vm.selectedApp = "Removed app"
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

    /// Renders `RestyleMenuView` on its own (design 2e's open "Re-style ▾" popover) for a record with
    /// `veryCasual` — the style whose checkmark row this exercises — separately from `render()`'s
    /// full-page states, since the popover is never part of the page's own layout.
    @Test("renders the Re-style popover for design-fidelity comparison")
    func renderRestyleMenu() async throws {
        let directory = Self.rendersDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let bundle = makeBundle()
        let record = DictationRecord(id: 1,
                                     text: "can we push the meeting to thurs afternoon? need the numbers from finance first",
                                     rawText: "um so can we uh push the meeting to like thursday afternoon I mean I need the numbers from finance first",
                                     appName: "Slack", style: "veryCasual", language: "en", duration: 9, words: 15, createdAt: Date())
        let renderer = ImageRenderer(content: RestyleMenuView(record: record, model: bundle.vm)
            .background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 2
        guard let image = renderer.nsImage else {
            Issue.record("Failed to render the Re-style popover")
            return
        }
        try Self.writePNG(image, to: directory.appendingPathComponent("History-restyle-menu.png"))
    }

    @Test("expanded detail has the white surface and column separator drawn in canvas 2e")
    func cardStructure() throws {
        let record = DictationRecord(id: 1, text: "Inserted words", rawText: "Spoken words",
            appName: "Mail", style: "formal", language: "en", duration: 1, words: 2, createdAt: Date())
        let renderer = ImageRenderer(content: HistoryDetailView(record: record)
            .frame(width: 860, height: 230).background(Color.white).environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let directory = Self.rendersDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.writePNG(image, to: directory.appendingPathComponent("History-card-structure.png"))
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let scale = CGFloat(bitmap.pixelsWide) / 860
        func red(at x: Int) throws -> CGFloat {
            try #require(bitmap.colorAt(x: Int(CGFloat(x) * scale), y: Int(110 * scale))?
                .usingColorSpace(.deviceRGB)).redComponent
        }
        // Samples avoid text: plain white within the left column, then the 6% black separator
        // through the middle gutter. A narrow band tolerates the separator's pixel alignment.
        #expect(try red(at: 200) > 0.99)
        let divider = try #require(try (428...431).map { try red(at: $0) }.min())
        #expect(divider > 0.90 && divider < 0.96)
    }

    @Test("renders app and date filter choices using the live popover content")
    func renderFilters() async throws {
        let directory = Self.rendersDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, options) in [
            ("apps", HistoryFilterOptions(choices: ["Mail", "Notes", "Slack", "Xcode"], selected: "Mail", allLabel: "All apps") { _ in }),
            ("dates", HistoryFilterOptions(choices: HistoryViewModel.DateRange.allCases.map(\.rawValue), selected: "This week") { _ in }),
        ] {
            let renderer = ImageRenderer(content: options.background(Color(nsColor: .windowBackgroundColor)))
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            try Self.writePNG(image, to: directory.appendingPathComponent("History-filter-\(name).png"))
        }
    }

    /// Native popover chrome needs an interactive computer capture. Run this fixture with both
    /// TEST_RUNNER_VOXFLOW_RENDER=1 and TEST_RUNNER_VOXFLOW_CAPTURE_POPOVERS=1, then open the app
    /// chip and choose Mail, and open the date chip and choose Today. Static render success alone
    /// does not establish this native interaction check. Foreground activation is owned by the
    /// interactive driver: NSApplication.activate() is only a request and cannot make automated
    /// mouse posting reliable in a background test host.
    @Test("manually inspects native filter popovers and captures the selected production page",
          .enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_CAPTURE_POPOVERS"] == "1"),
          .timeLimit(.minutes(5)))
    func renderNativeFilters() async throws {
        let directory = Self.rendersDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bundle = makeBundle()
        await seed(bundle)
        await bundle.vm.load()
        let host = NSHostingView(rootView: HistoryPageBody(viewModel: bundle.vm, ephemeralScope: EphemeralScope())
            .frame(width: 900, height: 600).background(Color.white).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        try Self.captureNative(host, name: "native-list", directory: directory)
        for name in ["native-app-popover", "native-date-popover"] {
            let shown = NativePopoverObserver()
            defer { shown.finish() }
            print("Native fixture ready to open: \(name)")
            await shown.wait()
            let popover = try #require(shown.popover)
            defer { popover.close() }
            // AppKit's material background is compositor-only; use computer capture for the
            // open popover. Native page PNGs record the list before and after selection.
            print("Native popover ready for capture: \(name)")
            let closed = NativePopoverObserver(event: NSPopover.didCloseNotification)
            defer { closed.finish() }
            await closed.wait()
        }
        try #require(bundle.vm.selectedApp == "Mail")
        try #require(bundle.vm.dateRange == .today)
        host.layoutSubtreeIfNeeded()
        try Self.captureNative(host, name: "native-selected", directory: directory)
    }

    private static func captureNative(_ view: NSView, name: String, directory: URL) throws {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("History-\(name).png"))
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
                HistorySearchChips(viewModel: viewModel)
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
            let hidesFooter: Bool = switch viewModel.emptyState {
                case .historyOff, .unavailable: true
                case .noDictations, .noResults, nil: false
            }
            if !hidesFooter {
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

/// Notification-driven: no arbitrary delay for the native popover animation.
@MainActor
private final class NativePopoverObserver {
    var popover: NSPopover?
    private var token: (any NSObjectProtocol)?
    private let shown = AsyncStream<Void>.makeStream()
    init(event: Notification.Name = NSPopover.didShowNotification) {
        token = NotificationCenter.default.addObserver(forName: event,
                                                        object: nil, queue: .main) { [weak self] notification in
            let popover = notification.object as? NSPopover
            // Foundation delivers this observer on OperationQueue.main, the main actor's executor.
            MainActor.assumeIsolated {
                self?.popover = popover
                self?.shown.continuation.yield()
            }
        }
    }
    func wait() async { for await _ in shown.stream { return } }
    func finish() {
        if let token { NotificationCenter.default.removeObserver(token) }
        shown.continuation.finish()
    }
}
