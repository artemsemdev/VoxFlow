import Foundation
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlowStorage

@Suite("Retention", .timeLimit(.minutes(1)))
struct RetentionTests {
    @Test("policy cutoff is now minus days; 0 days means keep forever")
    func policy() {
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        #expect(RetentionPolicy(days: 30).cutoff(now: now) == Date(timeIntervalSince1970: 70 * 86_400))
        #expect(RetentionPolicy(days: 0).cutoff(now: now) == nil)
        #expect(RetentionPolicy.default.days == 30)
        #expect(RetentionPolicy.choices == [7, 30, 90, 365, 0])
    }

    @Test("runner purges at start and again every 24 h using the injected clocks")
    func runner() async throws {
        let store = try DictationStore(inMemoryWith: nil)
        let wall = Mutex(Date(timeIntervalSince1970: 40 * 86_400))
        _ = try store.insert(DictationDraft(text: "old", rawText: "old", appName: nil, style: nil, language: nil, duration: 1, createdAt: Date(timeIntervalSince1970: 5 * 86_400)))
        _ = try store.insert(DictationDraft(text: "fresh", rawText: "fresh", appName: nil, style: nil, language: nil, duration: 1, createdAt: Date(timeIntervalSince1970: 39 * 86_400)))
        let clock = FakeClock()
        let runner = RetentionRunner(store: store, policy: { RetentionPolicy(days: 30) }, now: { wall.withLock { $0 } }, clock: clock)
        await runner.start()
        await runner.waitForPass(1)
        #expect(try store.fetch(limit: 10).map(\.text) == ["fresh"])
        wall.withLock { $0 = Date(timeIntervalSince1970: 70 * 86_400) }
        await clock.waitForSleepers(1)
        await clock.advance(by: 86_400)
        await runner.waitForPass(2)
        #expect(try store.count() == 0)
        await runner.stop()
    }
}
