import Foundation
import Testing
@testable import VoxFlowMCP

@Suite("ClientRegistry")
struct ClientRegistryTests {
    private let registry = ClientRegistry()
    private let cursor = MCPClientIdentity(name: "Cursor", path: "/Applications/Cursor.app/Contents/MacOS/Cursor", pid: 4812)

    @Test("an identity with no prior state is asked about")
    func unknownAsks() {
        let decision = registry.decision(for: cursor, approved: [], deniedThisSession: [], allowedOnce: [])
        #expect(decision == .ask)
    }

    @Test("an approved key is allowed")
    func approvedAllows() {
        let key = ClientRegistry.key(cursor)
        let decision = registry.decision(for: cursor, approved: [key], deniedThisSession: [], allowedOnce: [])
        #expect(decision == .allow)
    }

    @Test("a key denied this session is denied")
    func deniedThisSessionDenies() {
        let key = ClientRegistry.key(cursor)
        let decision = registry.decision(for: cursor, approved: [], deniedThisSession: [key], allowedOnce: [])
        #expect(decision == .deny)
    }

    @Test("a key allowed once is allowed")
    func allowedOnceAllows() {
        let key = ClientRegistry.key(cursor)
        let decision = registry.decision(for: cursor, approved: [], deniedThisSession: [], allowedOnce: [key])
        #expect(decision == .allow)
    }

    @Test("the key ignores pid: the same name and path with different pids share a decision")
    func keyIgnoresPID() {
        let restarted = MCPClientIdentity(name: cursor.name, path: cursor.path, pid: 9999)
        #expect(ClientRegistry.key(cursor) == ClientRegistry.key(restarted))
        let key = ClientRegistry.key(cursor)
        let decision = registry.decision(for: restarted, approved: [key], deniedThisSession: [], allowedOnce: [])
        #expect(decision == .allow)
    }

    @Test("a denied-this-session key takes precedence over an approved key")
    func denyTakesPrecedenceOverApproved() {
        let key = ClientRegistry.key(cursor)
        let decision = registry.decision(for: cursor, approved: [key], deniedThisSession: [key], allowedOnce: [])
        #expect(decision == .deny)
    }

    @Test("two different apps get independent keys")
    func differentAppsDifferentKeys() {
        let other = MCPClientIdentity(name: "Claude Desktop", path: "/Applications/Claude.app/Contents/MacOS/Claude", pid: 100)
        #expect(ClientRegistry.key(cursor) != ClientRegistry.key(other))
    }
}
