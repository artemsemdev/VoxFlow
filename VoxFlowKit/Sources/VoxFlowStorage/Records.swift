import Foundation
import VoxFlowCore

/// What kind of proper noun a dictionary entry is (design Dictionary tab); drives icon/grouping in UI.
public enum DictionaryEntryType: String, Sendable, Codable, CaseIterable {
    case name, term, product, place

    public var displayName: String {
        switch self {
        case .name: "Name"
        case .term: "Term"
        case .product: "Product"
        case .place: "Place"
        }
    }
}

/// A row in `dictionary`: a word Speech should recognize, optionally with a phonetic hint and a
/// typo autocorrection.
public struct DictionaryEntry: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var word: String
    public var soundsLike: String?
    public var type: DictionaryEntryType
    public var fixTyping: Bool
    public var source: String
    public var uses: Int
    public var createdAt: Date

    public init(id: Int64, word: String, soundsLike: String?, type: DictionaryEntryType, fixTyping: Bool, source: String, uses: Int, createdAt: Date) {
        self.id = id
        self.word = word
        self.soundsLike = soundsLike
        self.type = type
        self.fixTyping = fixTyping
        self.source = source
        self.uses = uses
        self.createdAt = createdAt
    }
}

/// A row in `snippets`: typing a trigger expands to `body`, optionally scoped to one app.
public struct Snippet: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var trigger: String
    public var body: String
    public var onlyInBundleID: String?
    public var onlyInAppName: String?
    public var uses: Int
    public var createdAt: Date

    public init(id: Int64, trigger: String, body: String, onlyInBundleID: String?, onlyInAppName: String?, uses: Int, createdAt: Date) {
        self.id = id
        self.trigger = trigger
        self.body = body
        self.onlyInBundleID = onlyInBundleID
        self.onlyInAppName = onlyInAppName
        self.uses = uses
        self.createdAt = createdAt
    }
}

/// A row in `app_style_overrides`: the rewrite tone to use whenever dictation happens in this app,
/// overriding the global default.
public struct StyleOverride: Sendable, Equatable {
    public var bundleID: String
    public var appName: String
    public var style: TextStyle

    public init(bundleID: String, appName: String, style: TextStyle) {
        self.bundleID = bundleID
        self.appName = appName
        self.style = style
    }
}

/// A row in `mcp_clients`: an app that has connected to the loopback MCP server (design ST-06
/// "Connected clients"), keyed by name+path (never pid — ruling 5).
public struct MCPClientRecord: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var name: String
    public var path: String
    public var approved: Bool
    public var firstSeen: Date
    public var lastSeen: Date

    public init(id: Int64, name: String, path: String, approved: Bool, firstSeen: Date, lastSeen: Date) {
        self.id = id
        self.name = name
        self.path = path
        self.approved = approved
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}
