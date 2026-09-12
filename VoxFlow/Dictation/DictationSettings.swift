import Foundation
import Synchronization
import VoxFlowCore
import VoxFlowDictation

/// Sendable view of the settings the dictation loop reads off the main actor.
struct DictationSettingsSnapshot: Sendable, Equatable {
    var excludedBundleIDs: [String]
    var keepHistory: Bool
    var options: TranscriptionOptions
    var audioProcessing = MicrophoneProcessingOptions()
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

    /// `UserDefaults` key names, shared with any Sendable-context reader that can't touch this
    /// main-actor-isolated class's properties directly (e.g. `AppServices.live()`'s `RetentionRunner`
    /// policy closure) — a single source of truth instead of a second copy of the literal.
    enum Keys {
        static let retentionDays = "privacy.retentionDays"
        static let shortcuts = "dictation.shortcuts"
    }

    /// Fired from `silenceStop`'s `didSet` (after clamping) so a live dictation's controller can
    /// pick up the new value — see `DictationController.updateConfig`.
    var onConfigChange: ((FlowBarConfig) -> Void)?
    /// Fired from `encryptHistory`/`retentionDays`'s `didSet`s so `HistoryService` can reopen the
    /// store with the new key policy / restart retention with the new window.
    var onHistorySettingsChange: (() -> Void)?
    var onShortcutsChange: (() -> Void)?
    private(set) var shortcuts = DictationShortcuts()

    @discardableResult
    func setShortcut(_ binding: ShortcutBinding, for action: ShortcutAction) -> Bool {
        guard binding.validationError(for: action) == nil else { return false }
        guard shortcuts[action] != binding else { return true }
        var updated = shortcuts
        updated[action] = binding
        guard updated.isValid else { return false }
        guard let data = try? JSONEncoder().encode(updated), let value = String(data: data, encoding: .utf8) else { return false }
        shortcuts = updated
        store.set(value, forKey: Keys.shortcuts)
        onShortcutsChange?()
        return true
    }

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
            onConfigChange?(flowBarConfig)
        }
    }
    var language: String? { didSet { store.set(language, forKey: "dictation.language"); sync() } }
    var noiseSuppression: Bool { didSet { store.set(noiseSuppression ? "1" : "0", forKey: "audio.noiseSuppression"); sync() } }
    var otherAudioReduction: MicrophoneProcessingOptions.Ducking {
        didSet { store.set(otherAudioReduction.rawValue, forKey: "audio.otherAudioReduction"); sync() }
    }
    var keepHistory: Bool { didSet { store.set(keepHistory ? "1" : "0", forKey: "privacy.keepHistory"); sync() } }
    var encryptHistory: Bool { didSet { store.set(encryptHistory ? "1" : "0", forKey: "privacy.encryptHistory"); onHistorySettingsChange?() } }
    var retentionDays: Int { didSet { store.set(String(retentionDays), forKey: Keys.retentionDays); onHistorySettingsChange?() } }
    var excludedBundleIDs: [String] { didSet { store.set(excludedBundleIDs.joined(separator: ","), forKey: "privacy.excludedApps"); sync() } }

    init(store: any KeyValueStore) {
        self.store = store
        if let data = store.string(forKey: Keys.shortcuts)?.data(using: .utf8),
           let saved = try? JSONDecoder().decode(DictationShortcuts.self, from: data), saved.isValid {
            shortcuts = saved
        }
        hotkeyMode = store.string(forKey: "dictation.hotkeyMode").flatMap(HotkeyMode.init(rawValue:)) ?? .pushToTalk
        silenceStop = FlowBarConfig(silenceStop: store.string(forKey: "dictation.silenceStop").flatMap(Double.init) ?? 3).silenceStop
        language = store.string(forKey: "dictation.language")
        noiseSuppression = store.string(forKey: "audio.noiseSuppression") == "1"
        otherAudioReduction = store.string(forKey: "audio.otherAudioReduction").flatMap(MicrophoneProcessingOptions.Ducking.init(rawValue:)) ?? .minimum
        keepHistory = store.string(forKey: "privacy.keepHistory") != "0"
        encryptHistory = store.string(forKey: "privacy.encryptHistory") != "0"
        retentionDays = store.string(forKey: Keys.retentionDays).flatMap(Int.init) ?? 30
        excludedBundleIDs = store.string(forKey: "privacy.excludedApps").map { $0.split(separator: ",").map(String.init) } ?? Self.defaultExcluded
        box = DictationSettingsBox(DictationSettingsSnapshot(excludedBundleIDs: [], keepHistory: true, options: TranscriptionOptions()))
        sync()
    }

    var flowBarConfig: FlowBarConfig { FlowBarConfig(silenceStop: silenceStop) }
    var transcriptionOptions: TranscriptionOptions { TranscriptionOptions(language: language) }
    var snapshot: DictationSettingsSnapshot { box.current }

    private func sync() {
        box.update(DictationSettingsSnapshot(excludedBundleIDs: excludedBundleIDs, keepHistory: keepHistory, options: transcriptionOptions,
                                             audioProcessing: .init(noiseSuppression: noiseSuppression, ducking: otherAudioReduction)))
    }
}
