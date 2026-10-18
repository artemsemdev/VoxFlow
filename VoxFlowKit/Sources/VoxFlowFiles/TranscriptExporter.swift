import Foundation
import VoxFlowCore

/// Retained by an exporter snapshot so replacing the selected folder cannot revoke its access.
public protocol ExportDirectoryAccess: Sendable {
    var directory: URL { get }
}

/// Writes rendered transcripts next to each other in one folder (design: "Save to ~/Transcripts").
public struct TranscriptExporter: Sendable {
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Transcripts", isDirectory: true)
    }

    public let directory: URL
    private let access: (any ExportDirectoryAccess)?

    public init(directory: URL = TranscriptExporter.defaultDirectory) { self.directory = directory; access = nil }
    public init(access: any ExportDirectoryAccess) { self.access = access; directory = access.directory }

    /// Writes `name.ext`, then `name-2.ext`, `name-3.ext`, … — an atomic exclusive-create write means
    /// two exporters racing on the same name can never overwrite each other's file.
    @discardableResult
    public func export(_ document: TranscriptDocument, format: OutputFormat, timestamps: Bool) throws -> URL {
        defer { withExtendedLifetime(access) {} }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = format.fileExtension
        let base = directory.appendingPathComponent(document.baseName)
        let rendered = TranscriptRenderer.render(document, format: format, timestamps: timestamps)
        var counter = 1
        while true {
            let url = counter == 1 ? base.appendingPathExtension(ext) : directory.appendingPathComponent("\(document.baseName)-\(counter)").appendingPathExtension(ext)
            do {
                try Data(rendered.utf8).write(to: url, options: [.withoutOverwriting])
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                counter += 1
            }
        }
    }

    public func exportAll(_ document: TranscriptDocument, formats: [OutputFormat], timestamps: Bool) throws -> [OutputFormat: URL] {
        var urls: [OutputFormat: URL] = [:]
        for format in formats { urls[format] = try export(document, format: format, timestamps: timestamps) }
        return urls
    }
}
