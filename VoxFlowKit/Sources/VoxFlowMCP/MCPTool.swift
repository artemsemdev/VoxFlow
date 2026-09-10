import Foundation

/// One tool VoxFlow exposes over MCP. Case order is the `tools/list` listing order.
public enum MCPToolID: Sendable, Equatable, CaseIterable {
    case transcribeFile
    case dictate
    case searchHistory

    /// The wire name (snake_case, per MCP convention), used in `tools/list` and `tools/call`.
    public var name: String {
        switch self {
        case .transcribeFile: return "transcribe_file"
        case .dictate: return "dictate"
        case .searchHistory: return "search_history"
        }
    }

    /// Resolves a tool from its wire name, as sent in `tools/call`'s `params.name`.
    public init?(toolName: String) {
        switch toolName {
        case "transcribe_file": self = .transcribeFile
        case "dictate": self = .dictate
        case "search_history": self = .searchHistory
        default: return nil
        }
    }

    public var descriptor: MCPToolDescriptor {
        switch self {
        case .transcribeFile:
            return MCPToolDescriptor(
                name: name,
                description: "Transcribe an audio file at a path; returns text or SRT",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(["type": .string("string")]),
                        "format": .object([
                            "type": .string("string"),
                            "enum": .array([.string("text"), .string("srt")]),
                        ]),
                    ]),
                    "required": .array([.string("path")]),
                ])
            )
        case .dictate:
            return MCPToolDescriptor(
                name: name,
                description: "Start a dictation and return the cleaned-up text",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                    "required": .array([]),
                ])
            )
        case .searchHistory:
            return MCPToolDescriptor(
                name: name,
                description: "Search past dictations — off by default",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object(["type": .string("string")]),
                        "limit": .object(["type": .string("integer")]),
                    ]),
                    "required": .array([.string("query")]),
                ])
            )
        }
    }
}

/// A tool as advertised to clients: its wire name, human-readable description, and JSON Schema
/// for `tools/call` arguments.
public struct MCPToolDescriptor: Sendable, Equatable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}
