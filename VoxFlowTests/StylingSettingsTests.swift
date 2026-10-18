import Foundation
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("StylingSettings")
@MainActor
struct StylingSettingsTests {
    @Test("defaults match the design; values persist across a reload from the same store")
    func defaultsAndPersistence() {
        let store = InMemoryKeyValueStore()
        let s = StylingSettings(store: store)
        #expect(s.defaultStyle == .casual)
        #expect(s.removeFillers)
        #expect(s.autoPunctuate)
        #expect(!s.snippetSayPrefix)
        #expect(!s.learnFromContacts)
        #expect(s.snapshot == StylingSettingsSnapshot(defaultStyle: .casual, removeFillers: true, autoPunctuate: true, snippetSayPrefix: false))

        s.defaultStyle = .formal
        s.removeFillers = false
        s.autoPunctuate = false
        s.snippetSayPrefix = true
        s.learnFromContacts = true

        let reloaded = StylingSettings(store: store)
        #expect(reloaded.defaultStyle == .formal)
        #expect(!reloaded.removeFillers)
        #expect(!reloaded.autoPunctuate)
        #expect(reloaded.snippetSayPrefix)
        #expect(reloaded.learnFromContacts)
    }

    @Test("box mirrors every setter, for a reader off the main actor")
    func boxMirrorsSettings() {
        let s = StylingSettings(store: InMemoryKeyValueStore())
        s.defaultStyle = .veryCasual
        s.removeFillers = false
        s.autoPunctuate = false
        s.snippetSayPrefix = true
        #expect(s.box.current == StylingSettingsSnapshot(defaultStyle: .veryCasual, removeFillers: false, autoPunctuate: false, snippetSayPrefix: true))
    }

    @Test("onChange fires on every setting change")
    func onChangeFiresOnEverySetting() {
        let s = StylingSettings(store: InMemoryKeyValueStore())
        var count = 0
        s.onChange = { count += 1 }
        s.defaultStyle = .formal
        #expect(count == 1)
        s.removeFillers = false
        #expect(count == 2)
        s.autoPunctuate = false
        #expect(count == 3)
        s.snippetSayPrefix = true
        #expect(count == 4)
        s.learnFromContacts = true
        #expect(count == 5)
    }
}
