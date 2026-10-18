import Testing
@testable import VoxFlowLLM

@Suite("LlamaParameters")
struct LlamaParametersTests {
    @Test("defaults context/batch/gpu layers and derives thread count from cores")
    func defaults() {
        let parameters = LlamaParameters(availableCores: 4)
        #expect(parameters.contextTokens == 2048)
        #expect(parameters.batchTokens == 512)
        #expect(parameters.gpuLayers == 99)
        #expect(parameters.threadCount == 4)
    }

    @Test("thread count is clamped to at least 1")
    func clampsLow() {
        #expect(LlamaParameters(availableCores: 0).threadCount == 1)
        #expect(LlamaParameters(availableCores: -3).threadCount == 1)
    }

    @Test("thread count is clamped to at most 8")
    func clampsHigh() {
        #expect(LlamaParameters(availableCores: 16).threadCount == 8)
        #expect(LlamaParameters(availableCores: 8).threadCount == 8)
    }
}
