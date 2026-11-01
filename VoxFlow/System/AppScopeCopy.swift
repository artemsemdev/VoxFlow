/// The same views explain the input scope of their distribution without changing their layout.
enum AppScopeCopy {
    static var welcome: String {
        AppCapabilities.inAppDictation
            ? "VoxFlow turns your voice into clean text inside VoxFlow — entirely on this Mac. Copy the result wherever you need it."
            : "VoxFlow turns your voice into clean text in any app — entirely on this Mac. Nothing you say ever leaves it."
    }
    static var snippets: String {
        AppCapabilities.inAppDictation
            ? "Type a trigger such as /sig in VoxFlow, or speak it while dictating."
            : "Type a trigger such as /sig, or speak it while dictating. Typing requires Accessibility access."
    }
    static var historyEmpty: String {
        AppCapabilities.inAppDictation
            ? "Hold fn in a VoxFlow text field and start talking. Saved dictations stay on this Mac. Scratchpad practice is not saved."
            : "Hold fn in any text field and start talking. Everything you dictate shows up here, on this Mac only."
    }
    static var overrideEmpty: String {
        AppCapabilities.inAppDictation
            ? "VoxFlow uses the default style above. Dictation stays inside VoxFlow."
            : "No overrides yet — every app uses the default style above."
    }
    static var hotkeyScope: String {
        AppCapabilities.inAppDictation ? " Shortcuts work while VoxFlow is active." : ""
    }
}
