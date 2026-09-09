import Foundation
import Testing
import VoxFlowCore
import VoxFlowTestSupport

@Suite("FakeClock", .timeLimit(.minutes(1)))
struct FakeClockTests {
    @Test("a sleep cancelled while it is registering never parks a sleeper nothing will resume")
    func cancelRacingRegistration() async throws {
        // Regression for the `LlamaStyler` timeout race hanging under load: `group.cancelAll()` can land
        // between `sleep`'s cancellation check and its registration. Race the two many times; every
        // sleeper must finish (throwing) and none may be left parked.
        let clock = FakeClock()
        for _ in 0..<300 {
            let sleeper = Task { try await clock.sleep(for: 10) }
            await Task.yield()
            sleeper.cancel()
            await #expect(throws: CancellationError.self) { try await sleeper.value }
        }
        #expect(clock.sleeperCount == 0)
    }

    @Test("advance resumes sleepers whose deadline passed, in deadline order")
    func advance() async throws {
        let clock = FakeClock()
        let order = OrderLog()
        let long = Task { try await clock.sleep(for: 2); await order.append("long") }
        let short = Task { try await clock.sleep(for: 1); await order.append("short") }
        await clock.waitForSleepers(2)
        await clock.advance(by: 1)
        _ = try await short.value
        #expect(await order.entries == ["short"])
        await clock.advance(by: 1)
        _ = try await long.value
        #expect(await order.entries == ["short", "long"])
        #expect(clock.now() == 2)
    }

    @Test("cancelling a sleeping task throws CancellationError and drops the sleeper")
    func cancel() async {
        let clock = FakeClock()
        let task = Task { try await clock.sleep(for: 5) }
        await clock.waitForSleepers(1)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await clock.sleeperCount == 0)
    }
}

actor OrderLog {
    var entries: [String] = []
    func append(_ s: String) { entries.append(s) }
}
