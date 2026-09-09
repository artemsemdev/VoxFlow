import CryptoKit
import Foundation
import Testing
import VoxFlowCore
import VoxFlowStorage
import VoxFlowTestSupport
@testable import VoxFlow

private struct FakeHistoryKeyProvider: HistoryKeyProviding {
    func historyKey() throws -> HistoryKey { HistoryKey(key: SymmetricKey(size: .bits256), isNewlyCreated: true) }
}

/// Fake `InstalledAppsProviding` — `names` maps bundle id → display name (missing ids fall back to
/// the id itself, mirroring the production lookup); `nextPick` is what `pickApplication()` returns.
private final class FakeInstalledApps: InstalledAppsProviding, @unchecked Sendable {
    var names: [String: String]
    var nextPick: String?
    private(set) var pickCallCount = 0
    init(names: [String: String] = [:], nextPick: String? = nil) {
        self.names = names
        self.nextPick = nextPick
    }
    func name(forBundleID bundleID: String) -> String? { names[bundleID] }
    @MainActor func pickApplication() async -> String? {
        pickCallCount += 1
        return nextPick
    }
}

@Suite("PrivacyViewModel") @MainActor
struct PrivacyViewModelTests {
    func makeService(dir: TemporaryDirectory, settings: DictationSettings) -> HistoryService {
        HistoryService(url: dir.file("voxflow.sqlite"), settings: settings, keyProvider: { FakeHistoryKeyProvider() }, clock: FakeClock())
    }

    // MARK: excluded apps

    @Test("excludedApps resolves names via the provider, falling back to the bundle id")
    func excludedAppsResolvesNames() {
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        settings.excludedBundleIDs = ["com.1password.1password", "com.unknown.app"]
        let apps = FakeInstalledApps(names: ["com.1password.1password": "1Password"])
        let dir = TemporaryDirectory()
        let model = PrivacyViewModel(settings: settings, history: makeService(dir: dir, settings: settings), apps: apps)

        #expect(model.excludedApps.map(\.bundleID) == ["com.1password.1password", "com.unknown.app"])
        #expect(model.excludedApps.map(\.name) == ["1Password", "com.unknown.app"])
    }

    @Test("addApp appends the picked bundle id, persisted through settings; no duplicates; remove drops it")
    func addAndRemovePersistThroughSettings() async {
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        settings.excludedBundleIDs = []
        let apps = FakeInstalledApps(nextPick: "com.example.discord")
        let dir = TemporaryDirectory()
        let model = PrivacyViewModel(settings: settings, history: makeService(dir: dir, settings: settings), apps: apps)

        await model.addApp()
        #expect(settings.excludedBundleIDs == ["com.example.discord"])
        #expect(model.excludedApps.map(\.bundleID) == ["com.example.discord"])

        await model.addApp()   // same pick again: no duplicate
        #expect(settings.excludedBundleIDs == ["com.example.discord"])
        #expect(apps.pickCallCount == 2)

        model.remove("com.example.discord")
        #expect(settings.excludedBundleIDs.isEmpty)
    }

    @Test("addApp is a no-op when the panel is cancelled")
    func addAppNoOpOnCancel() async {
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        settings.excludedBundleIDs = []
        let dir = TemporaryDirectory()
        let model = PrivacyViewModel(settings: settings, history: makeService(dir: dir, settings: settings), apps: FakeInstalledApps(nextPick: nil))

        await model.addApp()
        #expect(settings.excludedBundleIDs.isEmpty)
    }

    // MARK: delete all

    @Test("requestDeleteAll counts via the history service and sets the ST-05d alert text")
    func requestDeleteAllCountsAndAlerts() async {
        let dir = TemporaryDirectory()
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        let service = makeService(dir: dir, settings: settings)
        _ = await service.count()   // force the open to finish
        let store = try! #require(service.store)
        for i in 0..<3 {
            _ = try! store.insert(DictationDraft(text: "t\(i)", rawText: "t\(i)", appName: "Mail", style: nil, language: "en", duration: 1, createdAt: Date()))
        }
        let model = PrivacyViewModel(settings: settings, history: service, apps: FakeInstalledApps())

        await model.requestDeleteAll()
        #expect(model.alert == .deleteAll(count: 3))
        #expect(PrivacyViewModel.deleteAllTitle == "Delete all dictation history?")
        #expect(PrivacyViewModel.deleteAllMessage(count: 3) == "3 items will be removed from this Mac. There is no cloud copy, so this can't be undone.")
        #expect(PrivacyViewModel.deleteAllMessage(count: 1) == "1 item will be removed from this Mac. There is no cloud copy, so this can't be undone.")
    }

    @Test("confirmDeleteAll empties the service and clears the alert")
    func confirmDeleteAllEmptiesService() async {
        let dir = TemporaryDirectory()
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        let service = makeService(dir: dir, settings: settings)
        _ = await service.count()
        let store = try! #require(service.store)
        _ = try! store.insert(DictationDraft(text: "gone", rawText: "gone", appName: "Mail", style: nil, language: "en", duration: 1, createdAt: Date()))
        let model = PrivacyViewModel(settings: settings, history: service, apps: FakeInstalledApps())

        await model.requestDeleteAll()
        #expect(model.alert == .deleteAll(count: 1))
        await model.confirmDeleteAll()
        #expect(model.alert == nil)
        let remaining = await service.count()
        #expect(remaining == 0)
    }

    // MARK: encryption subtitle

    @Test("encryptionSubtitle mirrors HistoryKeyProviders.select for the injected availability")
    func encryptionSubtitleMirrorsKeyProviderChoice() {
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        let dir = TemporaryDirectory()
        let service = makeService(dir: dir, settings: settings)

        let secureEnclaveModel = PrivacyViewModel(settings: settings, history: service, apps: FakeInstalledApps(), secureEnclaveAvailable: { true })
        #expect(secureEnclaveModel.encryptionSubtitle == "Key stored in the Secure Enclave")

        let keychainModel = PrivacyViewModel(settings: settings, history: service, apps: FakeInstalledApps(), secureEnclaveAvailable: { false })
        #expect(keychainModel.encryptionSubtitle == "Key stored in the Keychain")
    }
}
