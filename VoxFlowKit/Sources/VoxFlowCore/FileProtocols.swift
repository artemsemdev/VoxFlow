import Foundation

public enum AudioDecodingError: Error, Equatable, Sendable {
    case fileNotFound(URL)
    /// The extension is not one VoxFlow accepts (design MW-06x: "Not an audio or video file").
    case unsupportedType(String)
    /// AVFoundation could not open or read the file ("Couldn't decode this file").
    case decodeFailed(String)
}

/// Decodes a file to engine-ready samples (implemented by `AudioDecoder`).
public protocol AudioDecoding: Sendable {
    func decode(_ url: URL) throws -> AudioSamples
}

/// Reads a file's duration cheaply, without decoding (queue header, > 4 h confirmation).
public protocol AudioDurationProviding: Sendable {
    func duration(of url: URL) async throws -> TimeInterval
}

public enum FileTranscriptionError: Error, Equatable, Sendable {
    case unsupportedType(String)
    case decodeFailed(String)
    case noModelInstalled
    case engineFailed(String)
    case cancelled
}

public enum FileTranscriptionUpdate: Sendable, Equatable {
    case loadingModel(modelID: String)
    case progress(Double)
}

/// Transcribes one file end to end, reporting model loading separately from 0…1 inference progress.
public protocol FileTranscribing: Sendable {
    func transcribe(_ url: URL, options: TranscriptionOptions,
                    update: @Sendable @escaping (FileTranscriptionUpdate) -> Void) async throws -> TranscriptDocument
}
