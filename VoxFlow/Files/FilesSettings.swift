import Foundation
import Synchronization
import VoxFlowCore
import VoxFlowFiles

/// A `Sendable` snapshot of `FilesSettings.transcriptionOptions`, kept in step by `FilesSettings`'
/// `didSet`s so a non-`@MainActor` reader (the file queue's actor) can see the current options
/// without hopping to the main actor.
final class OptionsSnapshot: Sendable {
    private let box: Mutex<TranscriptionOptions>

    init(_ initial: TranscriptionOptions) {
        box = Mutex(initial)
    }

    var current: TranscriptionOptions { box.withLock { $0 } }

    func update(_ options: TranscriptionOptions) {
        box.withLock { $0 = options }
    }
}

/// The Files page's persistent choices (design 1c Files › Output format / Batch mode / Timestamps / Language / Save to).
@Observable @MainActor
final class FilesSettings {
    private let store: any KeyValueStore
    let optionsSnapshot: OptionsSnapshot

    var outputFormat: OutputFormat { didSet { store.set(outputFormat.rawValue, forKey: "files.format") } }
    var batchMode: Bool { didSet { store.set(batchMode ? "1" : "0", forKey: "files.batch") } }
    var timestamps: Bool { didSet { store.set(timestamps ? "1" : "0", forKey: "files.timestamps") } }
    /// ISO 639-1 code or nil for auto-detect.
    var language: String? {
        didSet {
            store.set(language, forKey: "files.language")
            optionsSnapshot.update(transcriptionOptions)
        }
    }
    var outputFolder: URL { didSet { store.set(outputFolder.path, forKey: "files.outputFolder") } }

    init(store: any KeyValueStore) {
        self.store = store
        outputFormat = store.string(forKey: "files.format").flatMap(OutputFormat.init(rawValue:)) ?? .default
        batchMode = store.string(forKey: "files.batch") != "0"
        timestamps = store.string(forKey: "files.timestamps") != "0"
        let initialLanguage = store.string(forKey: "files.language")
        language = initialLanguage
        outputFolder = store.string(forKey: "files.outputFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? TranscriptExporter.defaultDirectory
        optionsSnapshot = OptionsSnapshot(TranscriptionOptions(language: initialLanguage))
    }

    var transcriptionOptions: TranscriptionOptions { TranscriptionOptions(language: language) }
}
