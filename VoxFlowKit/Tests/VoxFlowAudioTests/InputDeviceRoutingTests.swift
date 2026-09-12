import AudioToolbox
import Testing
import VoxFlowCore
@testable import VoxFlowAudio

@Suite("Capture input device routing")
struct InputDeviceRoutingTests {
    final class Node: InputDeviceNode {
        var device: AudioDeviceID = 1
        var writes: [AudioDeviceID] = []
        var ignoresSelection = false
        var rejectsSelection = false
        func selectInputDevice(_ id: AudioDeviceID) throws {
            writes.append(id)
            if rejectsSelection { throw MicrophoneError.engineFailed("fixture selection failure") }
            if !ignoresSelection { device = id }
        }
        func currentInputDevice() throws -> AudioDeviceID { device }
    }

    @Test("system default never pins or resolves an explicit device")
    func systemDefault() throws {
        let node = Node()
        let selected = try InputDeviceRouting.apply(uid: nil, to: node, resolve: { _ in
            Issue.record("default routing must not resolve a UID"); return nil
        })
        #expect(selected == nil)
        #expect(node.writes.isEmpty)
        node.device = 9 // A new OS default remains valid without pinning it.
        try InputDeviceRouting.verify(expected: selected, on: node)
    }

    @Test("an explicit UID is applied and verified again after voice processing or restart")
    func rebind() throws {
        let node = Node()
        let resolve: (String) -> AudioDeviceID? = { $0 == "chosen" ? 42 : nil }
        #expect(try InputDeviceRouting.apply(uid: "chosen", to: node, resolve: resolve) == 42)
        node.device = 1 // A replaced audio unit starts on the OS default.
        #expect(throws: MicrophoneError.noInputDevice) { try InputDeviceRouting.verify(expected: 42, on: node) }
        #expect(try InputDeviceRouting.apply(uid: "chosen", to: node, resolve: resolve) == 42)
        #expect(try InputDeviceRouting.apply(uid: "chosen", to: node, resolve: resolve) == 42)
        #expect(node.writes == [42, 42]) // No redundant property write / configuration loop.
    }

    @Test("a missing or disconnected selected UID fails without choosing another microphone")
    func unavailable() throws {
        let node = Node()
        #expect(throws: MicrophoneError.noInputDevice) {
            try InputDeviceRouting.apply(uid: "missing", to: node, resolve: { _ in nil })
        }
        #expect(node.writes.isEmpty)
        _ = try InputDeviceRouting.apply(uid: "chosen", to: node, resolve: { _ in 42 })
        #expect(throws: MicrophoneError.noInputDevice) {
            try InputDeviceRouting.apply(uid: "chosen", to: node, resolve: { _ in nil })
        }
        #expect(node.writes == [42])
    }

    @Test("a rejected or ignored native selection never succeeds", arguments: [false, true])
    func selectionFailure(rejected: Bool) {
        let node = Node()
        node.rejectsSelection = rejected; node.ignoresSelection = !rejected
        #expect(throws: (any Error).self) {
            try InputDeviceRouting.apply(uid: "chosen", to: node, resolve: { _ in 42 })
        }
        #expect(node.device == 1)
    }
}
