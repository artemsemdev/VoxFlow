import CryptoKit
import Foundation
import Testing
import VoxFlowCore
import VoxFlowStorage
import VoxFlowStyling
import VoxFlowTestSupport
@testable import VoxFlow

private struct FakeStylesKeyProvider: HistoryKeyProviding {
    let key = SymmetricKey(size: .bits256)
    func historyKey() throws -> HistoryKey { HistoryKey(key: key, isNewlyCreated: false) }
}

@Suite("StylesViewModel", .timeLimit(.minutes(1)))
@MainActor
struct StylesViewModelTests {
    @MainActor
    struct Harness {
        let dir = TemporaryDirectory()
        let settings: StylingSettings
        let service: HistoryService
        let content: ContentService

        init() {
            settings = StylingSettings(store: InMemoryKeyValueStore())
            service = HistoryService(url: dir.file("voxflow.sqlite"), settings: DictationSettings(store: InMemoryKeyValueStore()),
                                     keyProvider: { FakeStylesKeyProvider() }, clock: SystemMonotonicClock())
            content = ContentService(history: service)
        }

        func vm(apps: FakeInstalledAppsProvider = FakeInstalledAppsProvider()) -> StylesViewModel {
            StylesViewModel(content: content, stylingSettings: settings, installedApps: apps)
        }
    }

    // MARK: Default style selection

    @Test("defaultStyle reads and writes stylingSettings.defaultStyle, defaulting to casual")
    func defaultStylePersists() {
        let h = Harness()
        let vm = h.vm()
        #expect(vm.defaultStyle == .casual)

        vm.defaultStyle = .formal

        #expect(h.settings.defaultStyle == .formal)
        #expect(vm.defaultStyle == .formal)
    }

    @Test("the three cards are Formal, Casual, Very casual with the canvas's fixed sample copy")
    func cardsAreFixedCanvasCopy() {
        #expect(StylesViewModel.cards.map(\.style) == [.formal, .casual, .veryCasual])
        #expect(StylesViewModel.cards[0].sample == "Could we move the meeting to Thursday afternoon?")
        #expect(StylesViewModel.cards[1].sample == "Can we push the meeting to Thursday afternoon?")
        #expect(StylesViewModel.cards[2].sample == "can we push the meeting to thurs afternoon")
        #expect(StylesViewModel.saidSample == "um so yeah can we uh push the meeting to like thursday afternoon")
    }

    // MARK: Toggles

    @Test("removeFillers and autoPunctuate read and write stylingSettings, defaulting to true")
    func togglesPersist() {
        let h = Harness()
        let vm = h.vm()
        #expect(vm.removeFillers == true)
        #expect(vm.autoPunctuate == true)

        vm.removeFillers = false
        vm.autoPunctuate = false

        #expect(h.settings.removeFillers == false)
        #expect(h.settings.autoPunctuate == false)
    }

    // MARK: Per-app overrides

    @Test("addOverride adds a new per-app override and closes the sheet")
    func addOverride() async throws {
        let h = Harness()
        let vm = h.vm()
        await vm.load()
        vm.presentAddApp()
        vm.selectApp(bundleID: "com.linear", name: "Linear")
        vm.addAppSheet?.style = .veryCasual

        await vm.addOverride()

        #expect(vm.addAppSheet == nil)
        #expect(vm.overrides.map(\.bundleID) == ["com.linear"])
        #expect(vm.overrides[0].appName == "Linear")
        #expect(vm.overrides[0].style == .veryCasual)
    }

    @Test("addOverride is a no-op with no app selected")
    func addOverrideRequiresSelection() async throws {
        let h = Harness()
        let vm = h.vm()
        await vm.load()
        vm.presentAddApp()

        #expect(vm.canAddOverride == false)

        await vm.addOverride()

        #expect(vm.overrides.isEmpty)
        #expect(vm.addAppSheet != nil)
    }

    @Test("removeOverride removes the override locally and from storage")
    func removeOverride() async throws {
        let h = Harness()
        let vm = h.vm()
        await vm.load()
        vm.presentAddApp()
        vm.selectApp(bundleID: "com.linear", name: "Linear")
        await vm.addOverride()
        let override = vm.overrides[0]

        vm.removeOverride(override)

        #expect(vm.overrides.isEmpty)
        var remaining = await h.content.overrides.all()
        for _ in 0..<2_000 where !remaining.isEmpty {
            await Task.yield()
            remaining = await h.content.overrides.all()
        }
        #expect(remaining.isEmpty)
    }

    @Test("changeOverrideStyle updates the style locally and in storage")
    func changeOverrideStyle() async throws {
        let h = Harness()
        let vm = h.vm()
        await vm.load()
        vm.presentAddApp()
        vm.selectApp(bundleID: "com.linear", name: "Linear")
        vm.addAppSheet?.style = .casual
        await vm.addOverride()
        let override = vm.overrides[0]

        await vm.changeOverrideStyle(override, to: .verbatim)

        #expect(vm.overrides[0].style == .verbatim)
        let stored = await h.content.overrides.style(for: "com.linear")
        #expect(stored == .verbatim)
    }

    @Test("searchableApps excludes already-overridden apps and filters by search text")
    func searchableAppsFiltersAndExcludes() async throws {
        let h = Harness()
        let apps = FakeInstalledAppsProvider(apps: [("com.linear", "Linear"), ("com.tinyspeck.slackmacgap", "Slack"), ("com.notion", "Notion")])
        let vm = h.vm(apps: apps)
        await vm.load()
        vm.presentAddApp()
        vm.selectApp(bundleID: "com.linear", name: "Linear")
        await vm.addOverride()

        vm.presentAddApp()
        #expect(Set(vm.searchableApps.map(\.name)) == ["Slack", "Notion"])

        vm.addAppSheet?.search = "sla"
        #expect(vm.searchableApps.map(\.name) == ["Slack"])
    }

    // MARK: Resolver wiring (ruling 2 / ruling 8 — the History meta's style names come from here)

    @Test("StyleResolver picks the per-app override over the default when one exists, and the default otherwise")
    func resolverPicksOverrideOverDefault() async throws {
        let h = Harness()
        let vm = h.vm()
        await vm.load()
        vm.defaultStyle = .casual
        vm.presentAddApp()
        vm.selectApp(bundleID: "com.linear", name: "Linear")
        vm.addAppSheet?.style = .formal
        await vm.addOverride()

        let overridesMap = Dictionary(uniqueKeysWithValues: vm.overrides.map { ($0.bundleID, $0.style) })

        #expect(StyleResolver.resolve(default: vm.defaultStyle, overrides: overridesMap, bundleID: "com.linear") == .formal)
        #expect(StyleResolver.resolve(default: vm.defaultStyle, overrides: overridesMap, bundleID: "com.other") == .casual)
        #expect(StyleResolver.resolve(default: vm.defaultStyle, overrides: overridesMap, bundleID: nil) == .casual)
    }

    @Test("content.overridesBox reflects an added override — what StyledTranscriber reads for the History meta")
    func overridesBoxReflectsAddedOverride() async throws {
        let h = Harness()
        let vm = h.vm()
        await vm.load()
        vm.presentAddApp()
        vm.selectApp(bundleID: "com.linear", name: "Linear")
        vm.addAppSheet?.style = .verbatim

        await vm.addOverride()

        #expect(h.content.overridesBox.current["com.linear"] == .verbatim)
    }
}
