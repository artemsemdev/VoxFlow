import Foundation
import Testing
import VoxFlowCore
import VoxFlowDictation
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("DictationSettings")
@MainActor
struct DictationSettingsTests {
    @Test("voice processing defaults off and persisted levels reach the capture snapshot")
    func audioProcessing() {
        let store = InMemoryKeyValueStore()
        let settings = DictationSettings(store: store)
        #expect(settings.snapshot.audioProcessing == MicrophoneProcessingOptions())
        settings.noiseSuppression = true
        settings.otherAudioReduction = .maximum
        let restored = DictationSettings(store: store)
        #expect(restored.snapshot.audioProcessing == .init(noiseSuppression: true, ducking: .maximum))
        settings.noiseSuppression = false
        #expect(!settings.snapshot.audioProcessing.noiseSuppression)
    }
    @Test("defaults match the design; values persist and clamp")
    func defaults() {
        let store = InMemoryKeyValueStore()
        let s = DictationSettings(store: store)
        #expect(s.hotkeyMode == .pushToTalk)
        #expect(s.silenceStop == 3)
        #expect(s.language == nil)
        #expect(s.keepHistory && s.encryptHistory && s.retentionDays == 30)
        #expect(s.excludedBundleIDs == ["com.1password.1password", "com.apple.keychainaccess"])
        s.hotkeyMode = .handsFree
        s.silenceStop = 42
        s.excludedBundleIDs = ["com.example.a", "com.example.b"]
        s.language = "de"
        let reloaded = DictationSettings(store: store)
        #expect(reloaded.hotkeyMode == .handsFree)
        #expect(reloaded.silenceStop == 10)                       // clamped through FlowBarConfig
        #expect(reloaded.flowBarConfig.silenceStop == 10)
        #expect(reloaded.excludedBundleIDs == ["com.example.a", "com.example.b"])
        #expect(reloaded.transcriptionOptions.language == "de")
        #expect(reloaded.snapshot.excludedBundleIDs == ["com.example.a", "com.example.b"])
    }

    @Test("onConfigChange fires with the clamped FlowBarConfig whenever silenceStop changes")
    func onConfigChangeFiresWithClampedConfig() {
        let s = DictationSettings(store: InMemoryKeyValueStore())
        var received: [FlowBarConfig] = []
        s.onConfigChange = { received.append($0) }
        s.silenceStop = 7
        #expect(received.map(\.silenceStop) == [7])
        s.silenceStop = 42                                   // clamps to 10 before the hook fires
        #expect(received.map(\.silenceStop) == [7, 10])
    }

    @Test("onHistorySettingsChange fires on encryptHistory and retentionDays changes, not on unrelated settings")
    func onHistorySettingsChangeFiresOnHistorySettings() {
        let s = DictationSettings(store: InMemoryKeyValueStore())
        var count = 0
        s.onHistorySettingsChange = { count += 1 }
        s.encryptHistory = false
        #expect(count == 1)
        s.retentionDays = 7
        #expect(count == 2)
        s.hotkeyMode = .handsFree                            // unrelated setting: no history-settings hook
        #expect(count == 2)
    }
}
