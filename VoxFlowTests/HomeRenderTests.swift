import AppKit
import CryptoKit
import Foundation
import SwiftUI
import Testing
import VoxFlowCore
import VoxFlowDictation
import VoxFlowStorage
import VoxFlowTestSupport
@testable import VoxFlow

/// Design-fidelity renders (design MW-01, MW-01e) — gated behind `VOXFLOW_RENDER` so normal test
/// runs never touch disk. Run with
/// `VOXFLOW_RENDER=1 xcodebuild … -only-testing:VoxFlowTests/HomeRenderTests`, then compare the
/// PNGs in `.superpowers/design/renders/` against `canvas.pdf` pages 11-12 (MW-01) and 3 (MW-01e).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_RENDER"] != nil))
@MainActor
struct HomeRenderTests {
    private struct FakeHistoryKeyProvider: HistoryKeyProviding {
        func historyKey() throws -> HistoryKey { HistoryKey(key: SymmetricKey(size: .bits256), isNewlyCreated: false) }
    }

    private struct Bundle {
        let vm: HomeViewModel
        let history: HistoryService
    }

    /// A fixed Monday so the header/date line and week-chart day letters match the canvas exactly
    /// ("Monday, September 7", today's bar under "M").
    private static let now = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 15))!

    private func draft(_ text: String, appName: String, style: String, minutesAgo: Double) -> DictationDraft {
        DictationDraft(text: text, rawText: text, appName: appName, style: style, language: "en", duration: 12,
                       createdAt: Self.now.addingTimeInterval(-minutesAgo * 60))
    }

    private func makeBundle(microphone: PermissionState = .granted, accessibility: Bool = true,
                            modelStatus: HomeModelStatus = HomeModelStatus(readiness: .loaded, displayName: "large-v3-turbo"),
                            hotkeyMode: HotkeyMode = .pushToTalk) -> Bundle {
        let dir = TemporaryDirectory()
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        settings.retentionDays = 0
        settings.encryptHistory = false
        settings.hotkeyMode = hotkeyMode
        let navigation = Navigation()
        let history = HistoryService(url: dir.file("voxflow.sqlite"), settings: settings,
                                     keyProvider: { FakeHistoryKeyProvider() }, clock: FakeClock())
        let stats = StatsService(history: history, now: { Self.now }, fullUserName: { "Anh Nguyen" })
        let permissions = FakePermissions(microphone: microphone, requestResult: microphone, accessibility: accessibility)
        let vm = HomeViewModel(stats: stats, settings: settings, permissions: permissions,
                               modelStatus: { modelStatus }, navigation: navigation,
                               ephemeralScope: EphemeralScope(), now: { Self.now }, fullUserName: { "Anh Nguyen" })
        return Bundle(vm: vm, history: history)
    }

    /// Four "Recent" rows (matching the canvas examples) plus a spread of earlier-in-the-week
    /// dictations so the week chart shows varied bar heights, ending on `now`'s Monday.
    private func seedNormalWeek(_ bundle: Bundle) async {
        _ = await bundle.history.count()   // force the open to finish
        let store = bundle.history.store!
        _ = try! store.insert(draft("Hi Priya, attaching the signed NDA. Let me know if legal needs anything else.",
                                    appName: "Mail", style: "formal", minutesAgo: 2))
        _ = try! store.insert(draft("can we push the meeting to thurs afternoon? need the numbers from finance first",
                                    appName: "Slack", style: "veryCasual", minutesAgo: 14))
        _ = try! store.insert(draft("Ideas for the Q4 roadmap: batch transcription for the research team, a shared style library",
                                    appName: "Notes", style: "casual", minutesAgo: 60))
        _ = try! store.insert(draft("Refactor the audio buffer so the ring buffer is allocated once, then reused across takes",
                                    appName: "Xcode", style: "verbatim", minutesAgo: 180))
        for daysAgo in 1...5 {
            let words = Array(repeating: "word", count: daysAgo * 40).joined(separator: " ")
            _ = try! store.insert(DictationDraft(text: words, rawText: words, appName: "Mail", style: "formal", language: "en",
                                                 duration: 30, createdAt: Self.now.addingTimeInterval(-Double(daysAgo) * 24 * 3600)))
        }
    }

    @Test("renders Home states for design-fidelity comparison")
    func render() async throws {
        let directory = Self.rendersDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Case 1: normal MW-01 — stats, Recent, This week, everything-stays card.
        let normal = makeBundle()
        await seedNormalWeek(normal)
        await normal.vm.refresh()
        try await renderCase(normal.vm, name: "1-normal", directory: directory)

        // Case 2: MW-01e first run — no dictations ever, every setup row green, "Try it here".
        let firstRun = makeBundle()
        await firstRun.vm.refresh()
        try await renderCase(firstRun.vm, name: "2-first-run", directory: directory)

        // Case 3: a returning user (has dictated before) whose microphone permission was revoked —
        // ruling 3e: the Setup card returns on MW-01 with a red row.
        let permissionMissing = makeBundle(microphone: .denied)
        await seedNormalWeek(permissionMissing)
        await permissionMissing.vm.refresh()
        try await renderCase(permissionMissing.vm, name: "3-permission-missing", directory: directory)
    }

    private func renderCase(_ vm: HomeViewModel, name: String, directory: URL) async throws {
        let renderer = ImageRenderer(content: HomeRenderPreview(viewModel: vm)
            .frame(width: 1000, height: 780)
            .background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 2
        guard let image = renderer.nsImage else {
            Issue.record("Failed to render Home-\(name)")
            return
        }
        try Self.writePNG(image, to: directory.appendingPathComponent("Home-\(name).png"))
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

/// Renders `HomeContentView`'s content for `ImageRenderer`, reusing every content-bearing subview
/// with production (`HomeHeaderView`, `SetupCard`, `StatCardsRow`, `RecentList`, `WeekChart`,
/// `EverythingStaysOnYourMacCard`) — the only substitution is the first-run "Try it here" box: a
/// live `TextEditor` renders as a solid colour-filled glyph under `ImageRenderer` with no real
/// window behind it (confirmed empirically, same finding `HistoryRenderTests` documents for a live
/// `TextField`), so its placeholder text is drawn as plain `Text` instead.
private struct HomeRenderPreview: View {
    let viewModel: HomeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HomeHeaderView(title: viewModel.headerTitle, subtitle: viewModel.headerSubtitle, modeChip: viewModel.modeChip)
            if viewModel.showsSetupCard {
                SetupCard(rows: viewModel.setupRows, perform: viewModel.perform)
            }
            StatCardsRow(cards: viewModel.statCards)
            if viewModel.isFirstRun {
                tryItPreview
            } else {
                HStack(alignment: .top, spacing: 20) {
                    RecentList(rows: viewModel.recentRows, seeAll: viewModel.seeAll)
                        .frame(maxWidth: .infinity, alignment: .top)
                    VStack(spacing: 20) {
                        WeekChart(days: viewModel.week, totalText: viewModel.weekTotalText, calendar: .current)
                        EverythingStaysOnYourMacCard()
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }
        .padding(20)
    }

    private var tryItPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Try it here").font(.headline)
            Text("Hold fn and say anything. Release to see it appear.")
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.secondary.opacity(0.2)))
            Text("This scratchpad isn't saved to History.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.4)))
    }
}
