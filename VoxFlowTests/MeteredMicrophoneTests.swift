import Foundation
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("MeteredMicrophone", .timeLimit(.minutes(1)))
struct MeteredMicrophoneTests {
    @Test("forwards events and reports each chunk's RMS")
    func forwards() async throws {
        let base = FakeMicrophone()
        let levels = Mutex<[Float]>([])
        let metered = MeteredMicrophone(base: base) { rms in levels.withLock { $0.append(rms) } }
        let task = Task { () -> [MicrophoneEvent] in
            var out: [MicrophoneEvent] = []
            for try await e in metered.start() { out.append(e); if out.count == 2 { break } }
            return out
        }
        await base.waitUntilCapturing()
        base.emit(rms: 0.5, seconds: 0.01)
        base.emit(rms: 0.25, seconds: 0.01)
        let events = try await task.value
        #expect(events.count == 2)
        #expect(levels.withLock { $0 }.map { ($0 * 100).rounded() / 100 } == [0.5, 0.25])
        await base.waitUntilStopped()
    }
}
