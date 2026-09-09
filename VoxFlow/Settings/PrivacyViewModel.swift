import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers
import VoxFlowStorage

/// One installed application, as offered by the "Only in {app}" (MW-04a) / "Add app override"
/// (MW-05a) pickers. `url` backs the list row's icon (`NSWorkspace.shared.icon(forFile:)`, loaded
/// lazily by the view — not eagerly here, since decoding every icon during the scan would multiply
/// the exact per-render cost review B1 flagged, just moved earlier). `hostAppName` is the canvas's
/// trailing hint for a browser-installed "web app" shortcut ("Google Docs … Chrome"); `nil` for a
/// native app, whose hint is its bundle id instead (`AppListRow` in `AddAppOverrideSheet.swift`).
struct InstalledApp: Sendable, Equatable, Identifiable {
    let bundleID: String
    let name: String
    let url: URL?
    let hostAppName: String?

    var id: String { bundleID }

    init(bundleID: String, name: String, url: URL? = nil, hostAppName: String? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.url = url
        self.hostAppName = hostAppName
    }
}

/// Looks up display names for, and lets the user pick, installed applications (design ST-05 "Never
/// record in"). A protocol so tests can fake both without touching `NSWorkspace`/`NSOpenPanel`.
protocol InstalledAppsProviding: Sendable {
    /// The app's display name for `bundleID`, or nil when no such app is installed.
    func name(forBundleID bundleID: String) -> String?
    /// NSOpenPanel on `/Applications` restricted to `.application` — returns the picked app's bundle
    /// id, or nil if cancelled. `@MainActor`: `NSOpenPanel.runModal()` must run on the main thread,
    /// and this is an unisolated `async` protocol requirement otherwise.
    @MainActor func pickApplication() async -> String?
    /// Every installed application, for a searchable list (design MW-04a "New snippet"'s "Only in"
    /// picker, MW-05a "Add app override"'s app list) — alphabetical. This does real filesystem I/O
    /// (`WorkspaceInstalledApps`'s conformance), so callers must cache the result themselves (review
    /// B1) rather than call it from a computed property a view's `body` touches.
    /// Defaulted to `[]` below so existing conformers (test fakes elsewhere in the suite that only
    /// need `name`/`pickApplication`) don't have to implement it — kept deliberately (review M1
    /// suggested dropping this default and updating `PrivacyViewModelTests`'s private
    /// `FakeInstalledApps` instead, but that file is outside this task's file scope; flagged in the
    /// fix report as a skip, not silently dropped).
    func installedApps() -> [InstalledApp]
}

extension InstalledAppsProviding {
    func installedApps() -> [InstalledApp] { [] }
}

/// Production `InstalledAppsProviding`: `NSWorkspace` for the lookup, `NSOpenPanel` for picking, a
/// scan of the well-known application directories for the searchable list.
struct WorkspaceInstalledApps: InstalledAppsProviding {
    func name(forBundleID bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return Bundle(url: url)?.displayName
    }

    @MainActor func pickApplication() async -> String? {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }

    /// Scans `/Applications`, `/System/Applications` and `~/Applications` (top level only — no
    /// recursive descent into nested bundles, review M2) for `.app` bundles with a readable bundle
    /// id, deduplicated by id, sorted by display name. Callers (`SnippetsViewModel`/
    /// `StylesViewModel`) run this once per sheet presentation on a detached task and cache the
    /// result — this method itself stays synchronous so the production/test seam is a plain
    /// protocol method, not an async one.
    func installedApps() -> [InstalledApp] {
        let directories = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
        var seen = Set<String>()
        var result: [InstalledApp] = []
        for directory in directories {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            for item in items where item.hasSuffix(".app") {
                let url = URL(fileURLWithPath: directory).appendingPathComponent(item)
                guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier, !seen.contains(bundleID) else { continue }
                seen.insert(bundleID)
                result.append(InstalledApp(bundleID: bundleID, name: bundle.displayName ?? item, url: url,
                                           hostAppName: Self.hostAppName(forBundleID: bundleID)))
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Chrome/Edge give a browser-installed "web app" shortcut a bundle id under the browser's own
    /// namespace (`com.google.Chrome.app.<id>`, `com.microsoft.edgemac.app.<id>`) instead of a
    /// developer-chosen one — a cheap, dependency-free way to recover the canvas's "Google Docs …
    /// Chrome" hint without parsing each bundle's Info.plist for browser-specific keys. Not
    /// exhaustive of every possible browser-hosted-app convention.
    private static func hostAppName(forBundleID bundleID: String) -> String? {
        if bundleID.hasPrefix("com.google.Chrome.app.") { return "Chrome" }
        if bundleID.hasPrefix("com.microsoft.edgemac.app.") { return "Microsoft Edge" }
        return nil
    }
}

private extension Bundle {
    /// `CFBundleDisplayName`, falling back to `CFBundleName`, then the file name — mirrors how
    /// Finder/Spotlight name an app when the plist omits the display-name key.
    var displayName: String? {
        (object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
    }
}

/// Settings › Privacy (design ST-05, ST-05d). Toggles/pickers live directly on `settings`
/// (`DictationSettings`, exposed here so the view can `@Bindable` it); this view model owns the
/// derived bits: excluded-app names, the encryption subtitle, and the delete-all-history flow.
@Observable @MainActor
final class PrivacyViewModel {
    enum Alert: Equatable {
        case deleteAll(count: Int)
    }

    let settings: DictationSettings
    private let history: HistoryService
    private let apps: any InstalledAppsProviding
    private let secureEnclaveAvailable: () -> Bool

    var alert: Alert?

    init(settings: DictationSettings, history: HistoryService, apps: any InstalledAppsProviding,
         secureEnclaveAvailable: @escaping () -> Bool = { SecureEnclave.isAvailable }) {
        self.settings = settings
        self.history = history
        self.apps = apps
        self.secureEnclaveAvailable = secureEnclaveAvailable
    }

    /// "Never record in" rows — bundle id kept as the stable identity (for `remove`), display name
    /// resolved through `apps` with the bundle id itself as the fallback when the app isn't installed.
    var excludedApps: [(bundleID: String, name: String)] {
        settings.excludedBundleIDs.map { id in (id, apps.name(forBundleID: id) ?? id) }
    }

    /// I-4: a one-line status shown under the header when `HistoryService.status == .disabled` (e.g.
    /// the Keychain lost the encryption key) — nil while history is working, and nil for the
    /// service's own transient "not opened yet" startup placeholder, which isn't a real failure.
    /// `HistoryViewModel.EmptyState.unavailable` surfaces the same underlying reason on the History
    /// page; `readableReason` is shared so the two can't disagree.
    var historyUnavailableStatus: String? {
        guard case .disabled(let reason) = history.status, reason != HistoryService.notOpenedYetReason else { return nil }
        return "History storage unavailable this session — \(HistoryViewModel.readableReason(reason))"
    }

    /// ST-05 "Encrypt history at rest" subtitle — mirrors `HistoryService`'s own choice of key
    /// provider (`HistoryKeyProviders.select`), so the two can never disagree.
    var encryptionSubtitle: String {
        switch HistoryKeyProviders.select(secureEnclaveAvailable: secureEnclaveAvailable()) {
        case .secureEnclave: "Key stored in the Secure Enclave"
        case .keychain: "Key stored in the Keychain"
        }
    }

    func addApp() async {
        guard let bundleID = await apps.pickApplication(), !settings.excludedBundleIDs.contains(bundleID) else { return }
        settings.excludedBundleIDs.append(bundleID)
    }

    func remove(_ bundleID: String) {
        settings.excludedBundleIDs.removeAll { $0 == bundleID }
    }

    /// ST-05 "Delete all history…" — counts first so the alert can show "{n} items…" (ST-05d).
    func requestDeleteAll() async {
        alert = .deleteAll(count: await history.count())
    }

    func confirmDeleteAll() async {
        alert = nil
        await history.deleteAll()
    }

    func dismissAlert() { alert = nil }

    // MARK: Alert copy (design ST-05d)

    static let deleteAllTitle = "Delete all dictation history?"
    static func deleteAllMessage(count: Int) -> String {
        // Grouped like the canvas's "1,284 items" (ST-05d); en_US so the "," separator is stable in tests (POSIX has no grouping).
        let grouped = count.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
        return "\(grouped) item\(count == 1 ? "" : "s") will be removed from this Mac. There is no cloud copy, so this can't be undone."
    }
}
