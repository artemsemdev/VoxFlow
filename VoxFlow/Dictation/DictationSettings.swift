import Foundation
import Synchronization
import VoxFlowCore
import VoxFlowDictation

/// Sendable view of the settings the dictation loop reads off the main actor.
struct DictationSettingsSnapshot: Sendable, Equatable {
    var excludedBundleIDs: [String]
    var keepHistory: Bool
    var options: TranscriptionOptions
}

final class DictationSettingsBox: Sendable {
    private let box: Mutex<DictationSettingsSnapshot>
    init(_ initial: DictationSettingsSnapshot) { box = Mutex(initial) }
    var current: DictationSettingsSnapshot { box.withLock { $0 } }
    func update(_ s: DictationSettingsSnapshot) { box.withLock { $0 = s } }
}

/// Dictation and privacy choices (design ST-02 mode, ST-04 silence, ST-05 history/excluded apps).
@Observable @MainActor
final class DictationSettings {
    static let defaultExcluded = ["com.1password.1password", "com.apple.keychainaccess"]
    private let store: any KeyValueStore
    let box: DictationSettingsBox

    var hotkeyMode: HotkeyMode { didSet { store.set(hotkeyMode.rawValue, forKey: "dictation.hotkeyMode") } }
    var silenceStop: TimeInterval {
        didSet {
            // Reassigning `silenceStop` re-triggers this same `didSet` — guard so an out-of-range
            // value clamps in one bounce instead of recursing forever (each `didSet` unconditionally
            // fires again on assignment, even when the new value equals the current one).
            let clamped = FlowBarConfig(silenceStop: silenceStop).silenceStop
            if clamped != silenceStop {
                silenceStop = clamped
                return
            }
            store.set(String(silenceStop), forKey: "dictation.silenceStop")
        }
    }
    var language: String? { didSet { store.set(language, forKey: "dictation.language"); sync() } }
    var keepHistory: Bool { didSet { store.set(keepHistory ? "1" : "0", forKey: "privacy.keepHistory"); sync() } }
    var encryptHistory: Bool { didSet { store.set(encryptHistory ? "1" : "0", forKey: "privacy.encryptHistory") } }
    var retentionDays: Int { didSet { store.set(String(retentionDays), forKey: "privacy.retentionDays") } }
    var excludedBundleIDs: [String] { didSet { store.set(excludedBundleIDs.joined(separator: ","), forKey: "privacy.excludedApps"); sync() } }

    init(store: any KeyValueStore) {
        self.store = store
        hotkeyMode = store.string(forKey: "dictation.hotkeyMode").flatMap(HotkeyMode.init(rawValue:)) ?? .pushToTalk
        silenceStop = FlowBarConfig(silenceStop: store.string(forKey: "dictation.silenceStop").flatMap(Double.init) ?? 3).silenceStop
        language = store.string(forKey: "dictation.language")
        keepHistory = store.string(forKey: "privacy.keepHistory") != "0"
        encryptHistory = store.string(forKey: "privacy.encryptHistory") != "0"
        retentionDays = store.string(forKey: "privacy.retentionDays").flatMap(Int.init) ?? 30
        excludedBundleIDs = store.string(forKey: "privacy.excludedApps").map { $0.split(separator: ",").map(String.init) } ?? Self.defaultExcluded
        box = DictationSettingsBox(DictationSettingsSnapshot(excludedBundleIDs: [], keepHistory: true, options: TranscriptionOptions()))
        sync()
    }

    var flowBarConfig: FlowBarConfig { FlowBarConfig(silenceStop: silenceStop) }
    var transcriptionOptions: TranscriptionOptions { TranscriptionOptions(language: language) }
    var snapshot: DictationSettingsSnapshot { box.current }

    private func sync() {
        box.update(DictationSettingsSnapshot(excludedBundleIDs: excludedBundleIDs, keepHistory: keepHistory, options: transcriptionOptions))
    }
}
