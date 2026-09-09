/// Text-styling pipeline contracts (phase 4a dictionary/snippets/styles plan, ruling 1).
/// `RuleStyler` (VoxFlowStyling) is the phase-4a implementation; phase 5 swaps in an
/// LLM-backed `TextStyler` behind the same protocol.

/// Toggles that drive a `TextStyler` pass: the target tone plus the two global switches
/// (fillers, auto-punctuation) that sit under it on the Styles page (canvas MW-05).
public struct StylingOptions: Sendable, Equatable {
    public var style: TextStyle
    public var removeFillers: Bool
    public var autoPunctuate: Bool

    public init(style: TextStyle, removeFillers: Bool, autoPunctuate: Bool) {
        self.style = style
        self.removeFillers = removeFillers
        self.autoPunctuate = autoPunctuate
    }
}

/// Result of styling raw dictated text: the styled text, how many filler occurrences were
/// removed (for History/telemetry), and where the `cursor` snippet placeholder landed, if any.
public struct StyledText: Sendable, Equatable {
    public var text: String
    public var fillersRemoved: Int
    public var cursorOffset: Int?

    public init(text: String, fillersRemoved: Int, cursorOffset: Int? = nil) {
        self.text = text
        self.fillersRemoved = fillersRemoved
        self.cursorOffset = cursorOffset
    }
}

/// Rewrites raw dictation text according to `StylingOptions`. Implemented by `RuleStyler`
/// (phase 4a, deterministic) and later an LLM-backed styler (phase 5) — same call shape.
public protocol TextStyler: Sendable {
    func style(_ raw: String, options: StylingOptions) -> StyledText
}
