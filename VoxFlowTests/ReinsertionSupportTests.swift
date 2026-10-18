import Foundation
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowDictation
import VoxFlowStorage
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("ReinsertionSupport", .timeLimit(.minutes(1)))
struct ReinsertionSupportTests {
    static let mail = FrontmostApp(name: "Mail", bundleID: "com.apple.mail")
    static let record = DictationRecord(id: 1, text: "Edited text", rawText: "raw text",
        appName: "Notes", style: "formal", language: "en", duration: 2, words: 2, createdAt: .distantPast)

    func settings(keepHistory: Bool = true, excluded: [String] = []) -> DictationSettingsBox {
        DictationSettingsBox(.init(excludedBundleIDs: excluded, keepHistory: keepHistory,
                                    options: TranscriptionOptions()))
    }

    @Test("each insertion uses the current app and exclusions, and captures exactly the checked app")
    func freshTarget() async {
        let frontmost = ChangingFrontmost(), captured = CapturedApps(), box = settings()
        let support = ReinsertionSupport(frontmost: frontmost, settings: box,
            captureFocus: { app in captured.withLock { $0.append(app) } }, fetchLatest: { nil })
        #expect(await support.prepareTarget() == .ready)
        frontmost.update(app: FrontmostApp(name: "Notes", bundleID: "com.apple.Notes"))
        #expect(await support.prepareTarget() == .ready)
        box.update(.init(excludedBundleIDs: ["com.apple.Notes"], keepHistory: true, options: .init()))
        #expect(await support.prepareTarget() == .excluded("Notes"))
        #expect(captured.withLock { $0 } == [Self.mail, FrontmostApp(name: "Notes", bundleID: "com.apple.Notes")])
    }

    @Test("excluded apps and secure input never capture focus")
    func privacyGates() async {
        let captured = CapturedApps()
        for (app, secure, excluded, expected) in [
            (Self.mail, false, ["com.apple.mail"], "Mail"),
            (FrontmostApp(name: nil, bundleID: "blocked.app"), false, ["blocked.app"], "blocked.app"),
            (Self.mail, true, [], "a secure field")
        ] {
            let support = ReinsertionSupport(frontmost: FakeFrontmost(app: app, secure: secure),
                settings: settings(excluded: excluded),
                captureFocus: { app in captured.withLock { $0.append(app) } }, fetchLatest: { nil })
            #expect(await support.prepareTarget() == .excluded(expected))
        }
        #expect(captured.withLock { $0 }.isEmpty)
    }

    @Test("target preparation awaits focus capture before permitting insertion")
    func waitsForFocus() async {
        let entered = Gate(), release = Gate(), completed = Counter()
        let support = ReinsertionSupport(frontmost: FakeFrontmost(app: Self.mail, secure: false), settings: settings(),
            captureFocus: { _ in await entered.open(); await release.wait() }, fetchLatest: { nil })
        let operation = Task {
            let target = await support.prepareTarget()
            completed.withLock { $0 += 1 }
            return target
        }
        // This assertion also lets the intentionally empty implementation fail without parking
        // on an entry gate it never opens.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = await operation.value; await entered.open() }
            await entered.wait()
            #expect(completed.withLock { $0 } == 0)
            await release.open()
        }
        #expect(await operation.value == .ready)
    }

    @Test("privacy and app changes during focus capture invalidate preparation")
    func changedDuringCapture() async {
        for scenario in 0..<3 {
            let frontmost = ChangingFrontmost(), box = settings()
            let support = ReinsertionSupport(frontmost: frontmost, settings: box, captureFocus: { _ in
                switch scenario {
                case 0: box.update(.init(excludedBundleIDs: ["com.apple.mail"], keepHistory: true, options: .init()))
                case 1: frontmost.enableSecureInput()
                default: frontmost.update(app: FrontmostApp(name: "Notes", bundleID: "com.apple.Notes"))
                }
            }, fetchLatest: { nil })
            let expected: ReinsertionTarget = switch scenario {
            case 0: .excluded("Mail")
            case 1: .excluded("a secure field")
            default: .changed
            }
            #expect(await support.prepareTarget() == expected)
        }
    }

    @Test("history off never invokes the persisted lookup; enabling it uses the latest edited text")
    func historyToggle() async {
        let reads = Counter(), box = settings(keepHistory: false)
        let support = ReinsertionSupport(frontmost: FakeFrontmost(app: Self.mail, secure: false), settings: box,
            captureFocus: { _ in }, fetchLatest: { reads.withLock { $0 += 1 }; return Self.record })
        #expect(await support.lastSaved() == nil)
        #expect(reads.withLock { $0 } == 0)
        box.update(.init(excludedBundleIDs: [], keepHistory: true, options: .init()))
        let result = await support.lastSaved()
        #expect(result?.text == Self.record.text)
        #expect(result?.rawText == Self.record.rawText)
        #expect(result?.style == Self.record.style)
        #expect(result?.duration == Self.record.duration)
        #expect(reads.withLock { $0 } == 1)
    }

    @Test("disabling history during a lookup discards its result")
    func historyDisabledWhileReading() async {
        let box = settings(), reads = Counter()
        let support = ReinsertionSupport(frontmost: FakeFrontmost(app: Self.mail, secure: false), settings: box,
            captureFocus: { _ in }, fetchLatest: {
                reads.withLock { $0 += 1 }
                box.update(.init(excludedBundleIDs: [], keepHistory: false, options: .init()))
                return Self.record
            })
        #expect(await support.lastSaved() == nil)
        #expect(reads.withLock { $0 } == 1)
    }

    @Test("missing, unreadable and empty history records cannot become a replay")
    func unavailableHistory() async {
        var unreadable = Self.record, empty = Self.record
        unreadable.isUnreadable = true
        empty.text = ""
        for record in [nil, unreadable, empty] {
            let support = ReinsertionSupport(frontmost: FakeFrontmost(app: Self.mail, secure: false), settings: settings(),
                captureFocus: { _ in }, fetchLatest: { record })
            #expect(await support.lastSaved() == nil)
        }
    }

    final class ChangingFrontmost: FrontmostAppProviding {
        private let app = Mutex(ReinsertionSupportTests.mail)
        private let secure = Mutex(false)
        func update(app value: FrontmostApp) { app.withLock { $0 = value } }
        func enableSecureInput() { secure.withLock { $0 = true } }
        func frontmostApp() -> FrontmostApp { app.withLock { $0 } }
        func secureInputEnabled() -> Bool { secure.withLock { $0 } }
    }
}
