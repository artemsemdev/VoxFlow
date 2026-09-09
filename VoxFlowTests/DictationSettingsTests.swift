import Foundation
import Testing
import VoxFlowCore
import VoxFlowDictation
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("DictationSettings")
@MainActor
struct DictationSettingsTests {
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
}
