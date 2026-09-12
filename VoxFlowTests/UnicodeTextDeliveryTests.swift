import Foundation
import Testing
@testable import VoxFlow

@Suite("Guarded Unicode delivery") @MainActor
struct UnicodeTextDeliveryTests {
    @Test("UTF-16 chunks preserve all text and never split a surrogate pair",
          arguments: ["", "short", String(repeating: "a", count: 19) + "😀tail",
                      String(repeating: "👩🏽‍💻 cafe\u{301}\n", count: 8)])
    func chunkBoundaries(text: String) {
        let chunks = UnicodeTextDelivery.chunks(text)
        #expect(chunks.joined() == text)
        #expect(chunks.allSatisfy { !$0.isEmpty && $0.utf16.count <= 20 })
    }

    @Test("all event pairs are constructed before any posting")
    func constructsBeforePosting() {
        var events: [String] = []
        let sent = UnicodeTextDelivery.send(String(repeating: "a", count: 21), isValid: { true }) { chunk in
            events.append("build:\(chunk.utf16.count)")
            return { events.append("post:\(chunk.utf16.count)") }
        }
        #expect(sent)
        #expect(events == ["build:20", "build:1", "post:20", "post:1"])
    }

    @Test("a failed second event pair prevents every write")
    func constructionFailure() {
        var builds = 0, posts = 0
        let factory: UnicodeTextDelivery.PairFactory = { _ in
            builds += 1
            if builds == 2 { return nil }
            return { posts += 1 }
        }
        let sent = UnicodeTextDelivery.send(String(repeating: "a", count: 21), isValid: { true }, makePair: factory)
        #expect(!sent && builds == 2 && posts == 0)
    }

    @Test("invalid capture or target stops delivery before construction and between pairs")
    func invalidation() {
        var valid = false, builds = 0, posts = 0
        let factory: UnicodeTextDelivery.PairFactory = { _ in
            builds += 1
            return { posts += 1; valid = false }
        }
        #expect(!UnicodeTextDelivery.send("hello", isValid: { valid }, makePair: factory))
        #expect(builds == 0 && posts == 0)
        valid = true
        #expect(!UnicodeTextDelivery.send(String(repeating: "a", count: 41), isValid: { valid }, makePair: factory))
        #expect(builds == 3 && posts == 1)
    }

    @Test("framework detection uses only recognized framework directories in the app")
    func frameworkDetection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let frameworks = directory.appendingPathComponent("Contents/Frameworks")
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        #expect(!ChromiumAppFrameworks.containsSupportedFramework(in: directory))
        let framework = frameworks.appendingPathComponent("Electron Framework.framework")
        try Data().write(to: framework)
        #expect(!ChromiumAppFrameworks.containsSupportedFramework(in: directory))
        try FileManager.default.removeItem(at: framework)
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: false)
        #expect(ChromiumAppFrameworks.containsSupportedFramework(in: directory))
    }
}
