import Testing
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("MCPSettings")
@MainActor
struct MCPSettingsTests {
    @Test("defaults match the design (ruling 5: enabled off, transcribe_file/dictate on, search_history off)")
    func defaults() {
        let s = MCPSettings(store: InMemoryKeyValueStore(), token: FakeTokenStore())
        #expect(s.enabled == false)
        #expect(s.toolTranscribeFile == true)
        #expect(s.toolDictate == true)
        #expect(s.toolSearchHistory == false)
    }

    @Test("values persist across reloads")
    func persistence() {
        let store = InMemoryKeyValueStore()
        let s = MCPSettings(store: store, token: FakeTokenStore())
        s.enabled = true
        s.toolTranscribeFile = false
        s.toolDictate = false
        s.toolSearchHistory = true

        let reloaded = MCPSettings(store: store, token: FakeTokenStore())
        #expect(reloaded.enabled == true)
        #expect(reloaded.toolTranscribeFile == false)
        #expect(reloaded.toolDictate == false)
        #expect(reloaded.toolSearchHistory == true)
    }

    @Test("token is created on first read (vf_ + 32 lowercase hex) and stays stable across reads")
    func tokenCreatedOnFirstRead() {
        let tokenStore = FakeTokenStore()
        let s = MCPSettings(store: InMemoryKeyValueStore(), token: tokenStore)
        #expect(tokenStore.stored == nil)

        let token = s.token
        #expect(token.hasPrefix("vf_"))
        let hex = token.dropFirst(3)
        #expect(hex.count == 32)
        #expect(hex.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(tokenStore.stored == token)
        #expect(tokenStore.writeCount == 1)

        #expect(s.token == token)              // stable across repeat reads
        #expect(tokenStore.writeCount == 1)     // no re-write
    }

    @Test("token reuses whatever the store already had")
    func tokenReusesExisting() {
        let tokenStore = FakeTokenStore(stored: "vf_deadbeefdeadbeefdeadbeefdeadbeef")
        let s = MCPSettings(store: InMemoryKeyValueStore(), token: tokenStore)
        #expect(s.token == "vf_deadbeefdeadbeefdeadbeefdeadbeef")
        #expect(tokenStore.writeCount == 0)
    }

    @Test("maskedToken is vf_ + 12 bullets + the last 4 characters")
    func maskedToken() {
        let tokenStore = FakeTokenStore(stored: "vf_0123456789abcdef0123456789abcdef")
        let s = MCPSettings(store: InMemoryKeyValueStore(), token: tokenStore)
        #expect(s.maskedToken == "vf_" + String(repeating: "•", count: 12) + "cdef")
    }

    @Test("regenerate() writes and returns a new, different token")
    func regenerateProducesNewToken() {
        let tokenStore = FakeTokenStore()
        let s = MCPSettings(store: InMemoryKeyValueStore(), token: tokenStore)
        let original = s.token
        let regenerated = s.regenerate()
        #expect(regenerated != original)
        #expect(s.token == regenerated)
        #expect(tokenStore.stored == regenerated)
    }

    @Test("token generation still returns an in-memory value when the Keychain write fails")
    func tokenSurvivesWriteFailure() {
        let tokenStore = FakeTokenStore()
        tokenStore.setShouldThrow(true)
        let s = MCPSettings(store: InMemoryKeyValueStore(), token: tokenStore)
        let token = s.token
        #expect(token.hasPrefix("vf_"))
        #expect(tokenStore.stored == nil)       // write failed, nothing persisted
        #expect(s.token == token)               // still cached in-memory though
    }
}
