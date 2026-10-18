import Foundation
import Testing
@testable import VoxFlowMCP

@Suite("PathPolicy")
struct PathPolicyTests {
    private let home = URL(fileURLWithPath: "/Users/tester")
    private var policy: PathPolicy { PathPolicy(homeDirectory: home, allowedExtensions: ["wav", "mp3"]) }

    private func allExists(_ url: URL) -> Bool { true }
    private func isFile(_ url: URL) -> Bool { true }

    @Test("a file under the home directory with an allowed extension passes and returns the resolved URL")
    func allowedFilePasses() throws {
        let resolved = try policy.check("/Users/tester/Music/a.wav", fileExists: allExists, isRegularFile: isFile)
        #expect(resolved == URL(fileURLWithPath: "/Users/tester/Music/a.wav"))
    }

    @Test("a path outside the home directory is rejected")
    func outsideHomeRejected() {
        #expect(throws: PathPolicy.Rejection.outsideHome) {
            try policy.check("/etc/passwd", fileExists: allExists, isRegularFile: isFile)
        }
    }

    @Test("a path inside ~/Library is rejected even though it's under home")
    func insideLibraryRejected() {
        #expect(throws: PathPolicy.Rejection.insideLibrary) {
            try policy.check("/Users/tester/Library/x.wav", fileExists: allExists, isRegularFile: isFile)
        }
    }

    @Test("an unsupported extension is rejected, naming the extension")
    func unsupportedExtensionRejected() {
        #expect(throws: PathPolicy.Rejection.unsupportedType("txt")) {
            try policy.check("/Users/tester/Desktop/notes.txt", fileExists: allExists, isRegularFile: isFile)
        }
    }

    @Test("a relative path is rejected")
    func relativePathRejected() {
        #expect(throws: PathPolicy.Rejection.notAbsolute) {
            try policy.check("Music/a.wav", fileExists: allExists, isRegularFile: isFile)
        }
    }

    @Test("a '..' traversal inside home that resolves outside it is rejected")
    func dotDotTraversalRejected() {
        // `.standardizedFileURL` alone collapses "..", so this exercises path *normalization*,
        // not symlink resolution — see `symlinkResolvedBeforeJudging` below for the real thing.
        #expect(throws: PathPolicy.Rejection.outsideHome) {
            try policy.check("/Users/tester/Desktop/../../etc/passwd", fileExists: allExists, isRegularFile: isFile)
        }
    }

    /// Task 2 review, I5: the brief's actual test case — "a symlink in the home pointing at
    /// `/etc/passwd` → `.outsideHome` (proves resolution happens first)" — was never implemented;
    /// the `..`-traversal test above proves only that `.standardizedFileURL` normalizes, which
    /// `PathPolicy.check` would still pass even with `.resolvingSymlinksInPath()` deleted. This one
    /// creates a real symlink (same temp-directory precedent as `MCPClientStoreTests`'s on-disk
    /// migration test) whose *own* path is safely inside home but whose *target* is not, so it can
    /// only pass if the policy resolves symlinks before judging scope.
    @Test("a symlink inside home pointing at /etc/passwd is judged by its resolved target, not its own location")
    func symlinkResolvedBeforeJudging() throws {
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent("PathPolicyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let linkURL = tempHome.appendingPathComponent("escape.wav")
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: "/etc/passwd")

        let policyOverTempHome = PathPolicy(homeDirectory: tempHome, allowedExtensions: ["wav"])
        #expect(throws: PathPolicy.Rejection.outsideHome) {
            try policyOverTempHome.check(linkURL.path, fileExists: allExists, isRegularFile: isFile)
        }
    }

    @Test("a missing file is rejected")
    func missingFileRejected() {
        #expect(throws: PathPolicy.Rejection.notFound) {
            try policy.check("/Users/tester/Music/missing.wav", fileExists: { _ in false }, isRegularFile: isFile)
        }
    }

    @Test("a directory is rejected as not a regular file")
    func directoryRejected() {
        #expect(throws: PathPolicy.Rejection.notRegularFile) {
            try policy.check("/Users/tester/Music/looks-like-a-file.wav", fileExists: allExists, isRegularFile: { _ in false })
        }
    }

    @Test("every rejection's message is asserted verbatim")
    func rejectionMessages() {
        #expect(PathPolicy.Rejection.notAbsolute.message == "Path must be absolute.")
        #expect(PathPolicy.Rejection.notFound.message == "File not found.")
        #expect(PathPolicy.Rejection.notRegularFile.message == "Not a regular file.")
        #expect(PathPolicy.Rejection.outsideHome.message == "Outside your home directory.")
        #expect(PathPolicy.Rejection.insideLibrary.message == "Inside ~/Library.")
        #expect(PathPolicy.Rejection.unsupportedType("txt").message == "Unsupported file type: txt")
    }
}
