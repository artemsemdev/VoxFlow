import Foundation

/// Ruling 7: what paths the `transcribe_file` tool may read. Pure — takes injected `fileExists`/
/// `isRegularFile` closures rather than touching the filesystem itself, so it's fully unit-testable.
public struct PathPolicy: Sendable {
    public enum Rejection: Error, Equatable, Sendable {
        case notAbsolute
        case notFound
        case notRegularFile
        case outsideHome
        case insideLibrary
        case unsupportedType(String)

        public var message: String {
            switch self {
            case .notAbsolute: return "Path must be absolute."
            case .notFound: return "File not found."
            case .notRegularFile: return "Not a regular file."
            case .outsideHome: return "Outside your home directory."
            case .insideLibrary: return "Inside ~/Library."
            case .unsupportedType(let ext): return "Unsupported file type: \(ext)"
            }
        }
    }

    private let homeDirectory: URL
    private let allowedExtensions: Set<String>

    public init(homeDirectory: URL, allowedExtensions: Set<String>) {
        self.homeDirectory = homeDirectory
        self.allowedExtensions = allowedExtensions
    }

    /// Resolves symlinks first, so `~/Desktop/link-to-/etc/passwd` is judged by its target — a
    /// scope violation can't be laundered through a symlink whose own path looks fine. Cheap,
    /// string-only checks (home/Library scope, extension) run before the injected filesystem
    /// checks, so a scope violation never depends on `fileExists`/`isRegularFile`'s behavior.
    public func check(_ path: String, fileExists: (URL) -> Bool, isRegularFile: (URL) -> Bool) throws -> URL {
        guard path.hasPrefix("/") else { throw Rejection.notAbsolute }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL

        let homePath = homeDirectory.standardizedFileURL.path
        let resolvedPath = resolved.path
        guard resolvedPath == homePath || resolvedPath.hasPrefix(homePath + "/") else {
            throw Rejection.outsideHome
        }

        let libraryPath = homeDirectory.appendingPathComponent("Library").standardizedFileURL.path
        guard resolvedPath != libraryPath, !resolvedPath.hasPrefix(libraryPath + "/") else {
            throw Rejection.insideLibrary
        }

        let ext = resolved.pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else { throw Rejection.unsupportedType(resolved.pathExtension) }

        guard fileExists(resolved) else { throw Rejection.notFound }
        guard isRegularFile(resolved) else { throw Rejection.notRegularFile }

        return resolved
    }
}
