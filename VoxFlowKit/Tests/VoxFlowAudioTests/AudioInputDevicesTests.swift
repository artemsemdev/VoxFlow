import CoreAudio
import Synchronization
import Testing
@testable import VoxFlowAudio

@Suite("Audio input catalog notifications")
struct AudioInputDevicesTests {
    @Test("both hardware changes register and cancellation removes each listener once")
    func cancellation() async {
        let added = Mutex<[AudioObjectPropertySelector]>([])
        let removed = Mutex<[AudioObjectPropertySelector]>([])
        let stream = AudioInputDevices.changes { selector, changed in
            added.withLock { $0.append(selector) }
            changed()
            return { removed.withLock { $0.append(selector) } }
        }
        let task = Task { for await _ in stream {} }
        task.cancel()
        await task.value
        #expect(Set(added.withLock { $0 }) == [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice])
        #expect(removed.withLock { $0 }.sorted() == added.withLock { $0 }.sorted())
    }

    @Test("partial registration failure removes the earlier listener and finishes the stream")
    func partialFailure() async {
        let removed = Mutex<[AudioObjectPropertySelector]>([])
        let stream = AudioInputDevices.changes { selector, _ in
            if selector == kAudioHardwarePropertyDefaultInputDevice { return nil }
            return { removed.withLock { $0.append(selector) } }
        }
        var count = 0
        for await _ in stream { count += 1 }
        #expect(count == 0)
        #expect(removed.withLock { $0 } == [kAudioHardwarePropertyDevices])
    }
}
