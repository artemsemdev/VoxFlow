import Foundation
import VoxFlowCore
import VoxFlowStorage

/// One of the three selectable default-style cards (design MW-05) — `sample`/`description` are the
/// canvas's fixed strings (ruling 8: the Styles page's live samples are not computed by `RuleStyler`,
/// they're the mock's own copy).
struct StyleCard: Equatable {
    let style: TextStyle
    let sample: String
    let description: String
}

/// State and rules of the Styles page (design MW-05, 05a). Views render it; nothing else decides.
@Observable @MainActor
final class StylesViewModel {
    /// The "Add app override" sheet's draft (design MW-05a): search text over `installedApps`, the
    /// picked app, and the style to apply.
    struct AddAppOverrideDraft: Equatable {
        var search: String = ""
        var selectedBundleID: String?
        var selectedAppName: String?
        var style: TextStyle = .default
    }

    /// design MW-05's fixed "You said:" sample (ruling 8).
    static let saidSample = "um so yeah can we uh push the meeting to like thursday afternoon"

    /// design MW-05's three default-style cards, in display order.
    static let cards: [StyleCard] = [
        StyleCard(style: .formal, sample: "Could we move the meeting to Thursday afternoon?",
                 description: "Full sentences, no contractions. Good for Mail and documents."),
        StyleCard(style: .casual, sample: "Can we push the meeting to Thursday afternoon?",
                 description: "Your voice, tidied up. Fillers removed, punctuation added."),
        StyleCard(style: .veryCasual, sample: "can we push the meeting to thurs afternoon",
                 description: "Lowercase, light touch. Feels like a quick text."),
    ]

    /// The four styles offered by an override row's picker (ruling: "Verbatim (no cleanup)" label
    /// for verbatim) — `Verbatim` isn't one of the three default-style cards, only an override choice.
    static let overrideStyles: [TextStyle] = [.formal, .casual, .veryCasual, .verbatim]

    var overrides: [StyleOverride] = []
    var addAppSheet: AddAppOverrideDraft?

    let content: ContentService
    let stylingSettings: StylingSettings
    let installedApps: any InstalledAppsProviding

    /// The installed apps behind `searchableApps` — loaded once per `presentAddApp()` on a
    /// detached task and cached here, rather than re-running `installedApps.installedApps()`'s
    /// filesystem scan from `searchableApps` every time `body` re-evaluates it (review B1).
    private(set) var apps: [InstalledApp] = []

    init(content: ContentService, stylingSettings: StylingSettings, installedApps: any InstalledAppsProviding) {
        self.content = content
        self.stylingSettings = stylingSettings
        self.installedApps = installedApps
    }

    var defaultStyle: TextStyle {
        get { stylingSettings.defaultStyle }
        set { stylingSettings.defaultStyle = newValue }
    }

    var removeFillers: Bool {
        get { stylingSettings.removeFillers }
        set { stylingSettings.removeFillers = newValue }
    }

    var autoPunctuate: Bool {
        get { stylingSettings.autoPunctuate }
        set { stylingSettings.autoPunctuate = newValue }
    }

    func load() async {
        overrides = await content.overrides.all()
    }

    // MARK: "Add app override" sheet (design MW-05a)

    /// Scans installed apps once for this presentation (review B1) — `async` so callers (`Task {
    /// await … }` from the "+ Add app" button) can await the scan finishing before
    /// `searchableApps` needs `apps` populated.
    func presentAddApp() async {
        addAppSheet = AddAppOverrideDraft()
        await loadApps()
    }

    func cancelAddApp() {
        addAppSheet = nil
    }

    func selectApp(bundleID: String, name: String) {
        addAppSheet?.selectedBundleID = bundleID
        addAppSheet?.selectedAppName = name
    }

    var canAddOverride: Bool { addAppSheet?.selectedBundleID != nil }

    /// Apps offered by the search list: every cached installed app (see `apps`) not already
    /// overridden, filtered by the draft's search text (case-insensitive, matched against the
    /// display name) — filters the cache in-memory, no filesystem access (review B1).
    var searchableApps: [InstalledApp] {
        let overriddenIDs = Set(overrides.map(\.bundleID))
        let candidates = apps.filter { !overriddenIDs.contains($0.bundleID) }
        let query = (addAppSheet?.search ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return candidates }
        return candidates.filter { $0.name.lowercased().contains(query) }
    }

    /// The one-time-per-presentation scan (review B1): off the main actor, since
    /// `InstalledAppsProviding.installedApps()` does synchronous filesystem/Info.plist I/O.
    private func loadApps() async {
        let provider = installedApps
        apps = await Task.detached(priority: .utility) { provider.installedApps() }.value
    }

    func addOverride() async {
        guard let draft = addAppSheet, let bundleID = draft.selectedBundleID, let name = draft.selectedAppName else { return }
        try? await content.overrides.set(bundleID: bundleID, appName: name, style: draft.style)
        overrides = await content.overrides.all()
        addAppSheet = nil
    }

    // MARK: Override rows

    /// Removes the override locally and, on the returned task, from storage — the discardable
    /// `Task` (review M8) lets a test `await removeOverride(_:).value` deterministically instead of
    /// busy-polling for the write to land, while production call sites just ignore it.
    @discardableResult
    func removeOverride(_ override: StyleOverride) -> Task<Void, Never> {
        overrides.removeAll { $0.bundleID == override.bundleID }
        return Task { [content] in
            try? await content.overrides.remove(bundleID: override.bundleID)
        }
    }

    func changeOverrideStyle(_ override: StyleOverride, to style: TextStyle) async {
        if let index = overrides.firstIndex(where: { $0.bundleID == override.bundleID }) {
            overrides[index].style = style
        }
        try? await content.overrides.set(bundleID: override.bundleID, appName: override.appName, style: style)
    }
}
