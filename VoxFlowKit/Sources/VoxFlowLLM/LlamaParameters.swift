import Foundation

/// The numbers the engine hands to llama.cpp (plan ruling 3) — pure so tests can pin them.
public struct LlamaParameters: Sendable, Equatable {
    public var contextTokens: Int32 = 2048
    public var batchTokens: Int32 = 512
    public var threadCount: Int32
    public var gpuLayers: Int32 = 99

    public init(availableCores: Int) {
        threadCount = Int32(max(1, min(8, availableCores)))
    }
}
