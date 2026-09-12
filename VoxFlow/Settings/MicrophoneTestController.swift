import Foundation
import VoxFlowCore

@MainActor
protocol AudioSamplePlaying {
    func play(_ samples: [Float]) async throws
    func stop()
}

/// Five seconds maximum; no files, transcripts, history, clipboard or model are involved.
@Observable @MainActor
final class MicrophoneTestController {
    enum State { case idle, requestingPermission, recording, playing, stopping }
    private(set) var state: State = .idle
    private(set) var levels = Array(repeating: Float(0), count: 14)
    private(set) var message: String?
    private let microphone: any MicrophoneCapturing
    private let player: any AudioSamplePlaying
    private let permissions: any PermissionChecking
    private let clock: any MonotonicClock
    private let canStart: () -> Bool
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var samples: [Float] = []
    var bufferedSampleCount: Int { samples.count }
    var isRunning: Bool { state != .idle }

    init(microphone: any MicrophoneCapturing, player: any AudioSamplePlaying,
         permissions: any PermissionChecking, clock: any MonotonicClock = SystemMonotonicClock(),
         canStart: @escaping () -> Bool) {
        self.microphone = microphone; self.player = player; self.permissions = permissions
        self.clock = clock; self.canStart = canStart
    }

    func start() {
        guard task == nil else { return }
        guard canStart() else { message = "Finish dictation before testing the microphone."; return }
        state = .requestingPermission
        message = nil
        task = Task {
            defer {
                samples.removeAll(keepingCapacity: false)
                levels = Array(repeating: 0, count: 14)
                state = .idle; task = nil
            }
            do {
                let access = permissions.microphone() == .notDetermined
                    ? await permissions.requestMicrophone() : permissions.microphone()
                try Task.checkCancellation()
                guard access == .granted else { message = "Allow microphone access in System Settings to run a test."; return }
                guard canStart() else { message = "Finish dictation before testing the microphone."; return }
                state = .recording
                samples.reserveCapacity(80_000)
                let clock = clock
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await self.record() }
                    group.addTask { try await clock.sleep(for: 5) }
                    _ = try await group.next()
                    group.cancelAll()
                }
                try Task.checkCancellation()
                guard canStart() else { return }
                guard !samples.isEmpty else { message = "No microphone audio was received."; return }
                state = .playing
                let recorded = samples
                samples.removeAll(keepingCapacity: false)
                try await player.play(recorded)
                try Task.checkCancellation()
                message = "Test finished. Audio discarded."
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { message = "Microphone test failed: \(error.localizedDescription)" }
            }
        }
    }

    private func record() async throws {
        for try await event in microphone.start() {
            try Task.checkCancellation()
            guard canStart() else { throw CancellationError() }
            switch event {
            case .chunk(let chunk):
                samples.append(contentsOf: chunk.samples.prefix(max(0, 80_000 - samples.count)))
                levels.removeFirst(); levels.append(min(1, max(0, chunk.rms)))
                if samples.count == 80_000 {
                    // Cancelling the iterator's task terminates the source stream and its input tap.
                    withUnsafeCurrentTask { $0?.cancel() }
                    return
                }
            case .deviceChanged(let name):
                if name == nil { throw MicrophoneError.noInputDevice }
            }
        }
    }

    func stop() {
        guard task != nil else { return }
        state = .stopping
        task?.cancel()
        player.stop()
        samples.removeAll(keepingCapacity: false)
        levels = Array(repeating: 0, count: 14)
        message = nil
    }

    func waitUntilFinished() async { await task?.value }
}
