/// Rewrite tone applied to dictated text, either as the global default or a per-app override
/// (design §... Dictionary/Snippets/Styles phase). Stored as `rawValue` in `app_style_overrides`.
public enum TextStyle: String, Sendable, Codable, CaseIterable, Equatable {
    case formal, casual, veryCasual, verbatim

    public static let `default`: TextStyle = .casual

    public var displayName: String {
        switch self {
        case .formal: "Formal"
        case .casual: "Casual"
        case .veryCasual: "Very casual"
        case .verbatim: "Verbatim"
        }
    }
}
