import Foundation
import ObjectiveC
import Testing
import VoxFlowDictation

/// Inspect already-loaded images; this test starts no app services or external resources.
struct RuntimeLinkingTests {
    @Test("the hosted test process loads exactly one DictationController definition")
    func singleControllerDefinition() {
        let name = String(cString: class_getName(DictationController.self))
        var definingImages: [String] = []
        // The runtime copies this list under its lock; indexed dyld iteration would race other
        // test suites loading images. Class enumeration below also uses copied runtime data.
        var imageCount: UInt32 = 0
        let images = objc_copyImageNames(&imageCount)
        defer { free(images) }
        for index in 0..<Int(imageCount) {
            let path = images[index]
            var count: UInt32 = 0
            guard let names = objc_copyClassNamesForImage(path, &count) else { continue }
            defer { free(names) }
            if (0..<Int(count)).contains(where: { String(cString: names[$0]) == name }) {
                definingImages.append(String(cString: path))
            }
        }
        #expect(definingImages.count == 1, "Duplicate runtime definitions: \(definingImages)")
    }
}
