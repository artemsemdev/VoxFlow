import Testing
import VoxFlowCore
import VoxFlowModels
@testable import VoxFlow

@Suite("Model size text")
struct ModelSizeTextTests {
    @Test("matches the explicit decimal canvas values")
    func canvasValues() {
        #expect(ModelSizeText.format(1_624_555_275) == "1.6 GB")
        #expect(ModelSizeText.format(487_601_967) == "480 MB")
        #expect(ModelSizeText.format(744_000_000) == "740 MB")
    }

    @Test("Models and Flow Bar use the same formatter for every catalog entry")
    func sharedCallSites() {
        for model in ModelCatalog.all {
            let expected = ModelSizeText.format(model.sizeInBytes)
            #expect(ModelsViewModel.gigabytes(model.sizeInBytes) == expected)
            #expect(FlowBarContent.sizeText(model.sizeInBytes) == expected)
        }
    }
}
