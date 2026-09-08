import Foundation
import VoxFlowCore

public struct FakeAudioDuration: AudioDurationProviding {
    public var durations: [URL: TimeInterval]
    public init(_ durations: [URL: TimeInterval] = [:]) { self.durations = durations }
    public func duration(of url: URL) async throws -> TimeInterval {
        guard let seconds = durations[url] else { throw AudioDecodingError.decodeFailed("no duration for \(url.lastPathComponent)") }
        return seconds
    }
}
