@preconcurrency import AVFoundation
import Foundation
import VoxFlowCore

/// Duration via AVFoundation metadata (no decoding). Same extension gate as `AudioDecoder`.
public struct AudioDurationReader: AudioDurationProviding {
    public init() {}

    public func duration(of url: URL) async throws -> TimeInterval {
        let ext = url.pathExtension.lowercased()
        guard SupportedAudio.extensions.contains(ext) else { throw AudioDecodingError.unsupportedType(ext) }
        guard FileManager.default.fileExists(atPath: url.path) else { throw AudioDecodingError.fileNotFound(url) }
        do {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            guard seconds.isFinite, seconds >= 0 else { throw AudioDecodingError.decodeFailed("indefinite duration") }
            return seconds
        } catch let error as AudioDecodingError {
            throw error
        } catch {
            throw AudioDecodingError.decodeFailed(error.localizedDescription)
        }
    }
}
