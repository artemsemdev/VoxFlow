import VoxFlowCore

/// The system prompts (plan ruling 10) — exact strings, one per rewriting tone. `verbatim` has none.
public enum StylePrompts {
    static let tail = "Keep every fact, name, number and the original meaning, and write in the same language as the user's text. Do not add greetings, sign-offs, emoji, explanations or quotes. Reply with the rewritten text only."

    public static func system(for style: TextStyle) -> String? {
        switch style {
        case .formal:
            "You clean up dictated speech. Rewrite the user's text as clear, polite, professional language suitable for a work email: complete sentences, no contractions, correct punctuation and capitalization. " + tail
        case .casual:
            "You clean up dictated speech. Rewrite the user's text as natural, friendly everyday language, the way a person types a quick message to a colleague: light punctuation, contractions are fine, fix grammar and remove hesitations. " + tail
        case .veryCasual:
            "You clean up dictated speech. Rewrite the user's text as a short, relaxed chat message: lowercase is fine, minimal punctuation, contractions, brief and informal. " + tail
        case .verbatim:
            nil
        }
    }

    public static func prompt(for style: TextStyle, text: String) -> ChatPrompt? {
        system(for: style).map { ChatPrompt(system: $0, user: text) }
    }
}
