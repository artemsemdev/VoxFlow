import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers
import VoxFlowStorage

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
    /// picker, MW-05a "Add app override"'s app list) — bundle id + display name, alphabetical.
    /// Defaulted to `[]` below so existing conformers (test fakes that only need `name`/
    /// `pickApplication`) don't have to implement it.
    func installedApps() -> [(bundleID: String, name: String)]
}

extension InstalledAppsProviding {
    func installedApps() -> [(bundleID: String, name: String)] { [] }
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
    /// recursive descent into nested bundles) for `.app` bundles with a readable bundle id,
    /// deduplicated by id, sorted by display name.
    func installedApps() -> [(bundleID: String, name: String)] {
        let directories = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
        var seen = Set<String>()
        var result: [(bundleID: String, name: String)] = []
        for directory in directories {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            for item in items where item.hasSuffix(".app") {
                let url = URL(fileURLWithPath: directory).appendingPathComponent(item)
                guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier, !seen.contains(bundleID) else { continue }
                seen.insert(bundleID)
                result.append((bundleID, bundle.displayName ?? item))
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
