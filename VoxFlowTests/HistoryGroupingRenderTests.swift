import AppKit
import CryptoKit
import Foundation
import SwiftUI
import Testing
import VoxFlowCore
import VoxFlowStorage
import VoxFlowTestSupport
@testable import VoxFlow

private struct GroupingRenderKeyProvider: HistoryKeyProviding {
    let key = SymmetricKey(size: .bits256)
    func historyKey() throws -> HistoryKey { HistoryKey(key: key, isNewlyCreated: false) }
}

@Suite("History grouping renders",
       .enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_RENDER"] != nil))
@MainActor
struct HistoryGroupingRenderTests {
    private struct Bundle {
        let directory: TemporaryDirectory
        let service: HistoryService
        let model: HistoryViewModel
    }

    private func makeBundle() -> Bundle {
        let directory = TemporaryDirectory()
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        settings.retentionDays = 30
        settings.encryptHistory = true
        let service = HistoryService(directory: directory, settings: settings,
                                     keyProvider: { GroupingRenderKeyProvider() }, clock: SystemMonotonicClock())
        let model = HistoryViewModel(service: service, settings: settings, navigation: Navigation(),
                                     clock: SystemMonotonicClock(), initialDateRange: .allTime)
        return Bundle(directory: directory, service: service, model: model)
    }

    private func seed(_ bundle: Bundle) async {
        _ = await bundle.service.count()
        let calendar = Calendar.current
        let today = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let rows: [(String, String, String, Date)] = [
            ("Hi Priya, attaching the signed NDA. Let me know if legal needs anything else.", "Mail", "formal", today),
            ("can we push the meeting to thurs afternoon? need the numbers from finance first", "Slack", "veryCasual", today.addingTimeInterval(-600)),
            ("Ideas for the Q4 roadmap: batch transcription and a shared dictionary export.", "Notes", "casual", yesterday),
            ("Refactor the audio buffer so it is allocated once and reused between takes.", "Xcode", "verbatim", yesterday.addingTimeInterval(-600)),
        ]
        for (text, app, style, date) in rows {
            _ = try! bundle.service.store!.insert(DictationDraft(text: text, rawText: text, appName: app,
                style: style, language: "en", duration: 12, createdAt: date))
        }
        await bundle.model.load()
    }

    @Test("renders grouped, expanded, filtered and empty production pages in both appearances",
          arguments: ["grouped", "expanded", "filtered", "empty"], [false, true])
    func render(state: String, dark: Bool) async throws {
        let bundle = makeBundle()
        await seed(bundle)
        switch state {
        case "expanded": bundle.model.toggleExpanded(id: try #require(bundle.model.records.first?.id))
        case "filtered": bundle.model.selectedApp = "Notes"
        case "empty": bundle.model.selectedApp = "Missing app"
        default: break
        }
        let content = HistoryPageBody(viewModel: bundle.model, ephemeralScope: EphemeralScope())
            .frame(width: 900, height: 600)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.close() }
        host.frame = window.contentView!.bounds
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".superpowers/design/renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("History-groups-\(state)\(dark ? "-dark" : "").png"))
    }
}
