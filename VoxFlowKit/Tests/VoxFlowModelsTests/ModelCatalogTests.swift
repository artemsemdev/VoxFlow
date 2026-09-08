import Testing
import VoxFlowCore
@testable import VoxFlowModels

@Suite("ModelCatalog")
struct ModelCatalogTests {
    @Test("lists the design's three models with turbo as the speech default")
    func contents() {
        let ids = ModelCatalog.all.map(\.id)
        #expect(ids == ["whisper-large-v3-turbo", "whisper-small", "qwen2.5-3b-instruct-q4"])
        let defaults = ModelCatalog.all.filter(\.isDefault).map(\.id)
        #expect(defaults == ["whisper-large-v3-turbo", "qwen2.5-3b-instruct-q4"])
    }

    @Test("sizes and checksums match the published files")
    func sizesAndChecksums() {
        let turbo = ModelCatalog.model(id: "whisper-large-v3-turbo")!
        #expect(turbo.sizeInBytes == 1_624_555_275)
        #expect(turbo.sha256 == "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69")
        #expect(turbo.fileName == "ggml-large-v3-turbo.bin")
        let small = ModelCatalog.model(id: "whisper-small")!
        #expect(small.sizeInBytes == 487_601_967)
        #expect(small.sha256 == "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b")
        #expect(ModelCatalog.model(id: "nope") == nil)
    }
}
