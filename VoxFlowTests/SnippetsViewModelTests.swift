import CryptoKit
import Foundation
import Testing
import VoxFlowCore
import VoxFlowStorage
import VoxFlowTestSupport
@testable import VoxFlow

private struct FakeSnippetsKeyProvider: HistoryKeyProviding {
    let key = SymmetricKey(size: .bits256)
    func historyKey() throws -> HistoryKey { HistoryKey(key: key, isNewlyCreated: false) }
}

@Suite("SnippetsViewModel", .timeLimit(.minutes(1)))
@MainActor
struct SnippetsViewModelTests {
    @MainActor
    struct Harness {
        let dir = TemporaryDirectory()
        let settings: StylingSettings
        let service: HistoryService
        let content: ContentService

        init() {
            settings = StylingSettings(store: InMemoryKeyValueStore())
            service = HistoryService(url: dir.file("voxflow.sqlite"), settings: DictationSettings(store: InMemoryKeyValueStore()),
                                     keyProvider: { FakeSnippetsKeyProvider() }, clock: SystemMonotonicClock())
            content = ContentService(history: service)
        }

        func vm(apps: FakeInstalledAppsProvider = FakeInstalledAppsProvider()) -> SnippetsViewModel {
            SnippetsViewModel(content: content, stylingSettings: settings, installedApps: apps)
        }
    }

    // MARK: Save / validation

    @Test("save inserts a new snippet and closes the sheet")
    func saveInsertsSnippet() async throws {
        let h = Harness()
        let vm = h.vm()
        await vm.load()
        await vm.presentNew()
        vm.sheet?.trigger = "/sig"
        vm.sheet?.body = "Kind regards,\nAnh"

        await vm.save()

        #expect(vm.sheet == nil)
        #expect(vm.snippets.map(\.trigger) == ["/sig"])
        #expect(vm.snippets[0].body == "Kind regards,\nAnh")
    }

    @Test("validation is .empty for a blank trigger — Save disabled, no message")
    func emptyValidation() async throws {
        let h = Harness()
        let vm = h.vm()
        await vm.presentNew()

        #expect(vm.validation == .empty)
        #expect(vm.canSave == false)

        vm.sheet?.trigger = "   "
        #expect(vm.validation == .empty)
    }

    @Test("a blank Insert body is also .empty — Save disabled (review M7)")
    func blankBodyIsEmpty() async throws {
        let h = Harness()
        let vm = h.vm()
        await vm.presentNew()
        vm.sheet?.trigger = "/sig"

        #expect(vm.validation == .empty)
        #expect(vm.canSave == false)

        vm.sheet?.body = "   "
        #expect(vm.validation == .empty)

        vm.sheet?.body = "Kind regards"
        #expect(vm.validation == nil)
        #expect(vm.canSave == true)
    }

    @Test("a trigger missing the leading / is .invalid — Save disabled")
    func missingSlashIsInvalid() async throws {
        let h = Harness()
        let vm = h.vm()
        await vm.presentNew()
        vm.sheet?.trigger = "sig"

        guard case .invalid = vm.validation else {
            Issue.record("expected .invalid, got \(String(describing: vm.validation))")
            return
        }
        #expect(vm.canSave == false)
    }

    @Test("a trigger containing whitespace is .invalid — Save disabled")
    func whitespaceIsInvalid() async throws {
        let h = Harness()
        let vm = h.vm()
        await vm.presentNew()
        vm.sheet?.trigger = "/my sig"

        guard case .invalid = vm.validation else {
            Issue.record("expected .invalid, got \(String(describing: vm.validation))")
            return
        }
        #expect(vm.canSave == false)
    }

    @Test("validation is .duplicate for a trigger already used, quoting the existing snippet's first body line, with the /sig2 · /work-sig suggestion")
    func duplicateValidation() async throws {
        let h = Harness()
        let vm = h.vm()
        await vm.load()
        await vm.presentNew()
        vm.sheet?.trigger = "/sig"
        vm.sheet?.body = "Email signature\nSent from VoxFlow"
        await vm.save()

        await vm.presentNew()
        vm.sheet?.trigger = "/sig"

        guard case .duplicate(let existing, let message, let suggestion) = vm.validation else {
            Issue.record("expected .duplicate, got \(String(describing: vm.validation))")
            return
        }
        #expect(existing.trigger == "/sig")
        #expect(message == "/sig is already used by \u{201c}Email signature\u{201d}.")
        #expect(suggestion == "Triggers start with / and contain no spaces. Try /sig2 or /work-sig.")
        #expect(vm.canSave == false)
    }

    @Test("suggestion computation is /sig2 and /work-sig even from a trigger missing its slash")
    func suggestionFromMalformedTrigger() {
        #expect(SnippetsViewModel.suggestion(for: "sig") == "Triggers start with / and contain no spaces. Try /sig2 or /work-sig.")
        #expect(SnippetsViewModel.suggestion(for: "/sig") == "Triggers start with / and contain no spaces. Try /sig2 or /work-sig.")
    }

    @Test("editing an existing snippet is not a self-collision")
    func editingSelfIsNotDuplicate() async throws {
        let h = Harness()
        let vm = h.vm()
        await vm.load()
        await vm.presentNew()
        vm.sheet?.trigger = "/sig"
        vm.sheet?.body = "Kind regards"
        await vm.save()
        let existing = vm.snippets[0]

        await vm.editExisting(existing)

        #expect(vm.sheet?.trigger == "/sig")
        #expect(vm.sheet?.body == "Kind regards")
        #expect(vm.sheet?.editingID == existing.id)
        #expect(vm.validation == nil)
        #expect(vm.canSave == true)
    }

    @Test("editing and saving updates the snippet in place rather than inserting a new one")
    func editSavesInPlace() async throws {
        let h = Harness()
        let vm = h.vm()
        await vm.load()
        await vm.presentNew()
        vm.sheet?.trigger = "/sig"
        vm.sheet?.body = "Kind regards"
        await vm.save()
        let existing = vm.snippets[0]

        await vm.editExisting(existing)
        vm.sheet?.body = "Best,\nAnh"
        await vm.save()

        #expect(vm.snippets.count == 1)
        #expect(vm.snippets[0].id == existing.id)
        #expect(vm.snippets[0].body == "Best,\nAnh")
    }

    // MARK: spoken hint (ruling 4 / SnippetExpander spoken form)

    @Test("spokenHint derives \"slash <trigger>\" from the trigger")
    func spokenHintDerivation() async throws {
        let h = Harness()
        let vm = h.vm()
        await vm.presentNew()

        #expect(vm.spokenHint == nil)

        vm.sheet?.trigger = "/standup"
        #expect(vm.spokenHint == "spoken as \u{201c}slash standup\u{201d}")
    }

    // MARK: Empty-state prefill

    @Test("presentNew(prefillTrigger:) prefills the sheet — the empty state's Create /sig")
    func prefillsTrigger() async throws {
        let h = Harness()
        let vm = h.vm()

        await vm.presentNew(prefillTrigger: "/sig")

        #expect(vm.sheet?.trigger == "/sig")
        #expect(vm.sheet?.editingID == nil)
    }

    // MARK: Only in {app}

    @Test("enabling Only in picks the first installed app as a default")
    func onlyInPicksFirstApp() async throws {
        let h = Harness()
        let apps = FakeInstalledAppsProvider(apps: [("com.tinyspeck.slackmacgap", "Slack"), ("com.microsoft.teams", "Teams")])
        let vm = h.vm(apps: apps)
        await vm.presentNew()

        vm.setOnlyIn(true)

        #expect(vm.sheet?.onlyIn == true)
        #expect(vm.sheet?.onlyInBundleID == "com.tinyspeck.slackmacgap")
        #expect(vm.sheet?.onlyInAppName == "Slack")
    }

    @Test("choosing a different app updates the draft")
    func chooseOnlyInApp() async throws {
        let h = Harness()
        let apps = FakeInstalledAppsProvider(apps: [("com.tinyspeck.slackmacgap", "Slack"), ("com.microsoft.teams", "Teams")])
        let vm = h.vm(apps: apps)
        await vm.presentNew()
        vm.setOnlyIn(true)

        vm.chooseOnlyInApp(bundleID: "com.microsoft.teams")

        #expect(vm.sheet?.onlyInBundleID == "com.microsoft.teams")
        #expect(vm.sheet?.onlyInAppName == "Teams")
    }

    @Test("disabling Only in clears the app selection")
    func disablingOnlyInClears() async throws {
        let h = Harness()
        let apps = FakeInstalledAppsProvider(apps: [("com.tinyspeck.slackmacgap", "Slack")])
        let vm = h.vm(apps: apps)
        await vm.presentNew()
        vm.setOnlyIn(true)

        vm.setOnlyIn(false)

        #expect(vm.sheet?.onlyIn == false)
        #expect(vm.sheet?.onlyInBundleID == nil)
        #expect(vm.sheet?.onlyInAppName == nil)
    }

    @Test("saving with Only in stores the bundle id and app name")
    func saveWithOnlyIn() async throws {
        let h = Harness()
        let apps = FakeInstalledAppsProvider(apps: [("com.tinyspeck.slackmacgap", "Slack")])
        let vm = h.vm(apps: apps)
        await vm.load()
        await vm.presentNew()
        vm.sheet?.trigger = "/standup"
        vm.sheet?.body = "Yesterday:\nToday:"
        vm.setOnlyIn(true)

        await vm.save()

        #expect(vm.snippets[0].onlyInBundleID == "com.tinyspeck.slackmacgap")
        #expect(vm.snippets[0].onlyInAppName == "Slack")
    }

    @Test("saving without Only in stores no app scoping")
    func saveWithoutOnlyIn() async throws {
        let h = Harness()
        let vm = h.vm()
        await vm.load()
        await vm.presentNew()
        vm.sheet?.trigger = "/sig"
        vm.sheet?.body = "Kind regards"

        await vm.save()

        #expect(vm.snippets[0].onlyInBundleID == nil)
        #expect(vm.snippets[0].onlyInAppName == nil)
    }

    // MARK: Installed-apps scan caching (review B1)

    @Test("presentNew scans installed apps once per presentation — not per subsequent access")
    func presentNewScansAppsOnce() async throws {
        let h = Harness()
        let apps = FakeInstalledAppsProvider(apps: [("com.tinyspeck.slackmacgap", "Slack")])
        let vm = h.vm(apps: apps)

        await vm.presentNew()
        // Repeated reads (what a re-rendering `body`, or several keystrokes, would trigger) must
        // not re-scan — `apps` is a plain cached property now, not a computed pass-through.
        _ = vm.apps
        vm.sheet?.trigger = "/s"
        vm.sheet?.trigger = "/st"
        _ = vm.apps
        vm.setOnlyIn(true)
        vm.chooseOnlyInApp(bundleID: "com.tinyspeck.slackmacgap")

        #expect(apps.scanCount == 1)
    }

    @Test("editExisting also scans installed apps exactly once")
    func editExistingScansAppsOnce() async throws {
        let h = Harness()
        let apps = FakeInstalledAppsProvider(apps: [("com.tinyspeck.slackmacgap", "Slack")])
        let vm = h.vm(apps: apps)
        await vm.load()
        await vm.presentNew()
        vm.sheet?.trigger = "/sig"
        vm.sheet?.body = "Kind regards"
        await vm.save()
        let saved = vm.snippets[0]

        await vm.editExisting(saved)

        #expect(apps.scanCount == 2) // one from presentNew above, one from editExisting
    }

    // MARK: Insert cursor placeholder

    @Test("insertCursorPlaceholder appends cursor to the body")
    func insertCursorAppends() async throws {
        let h = Harness()
        let vm = h.vm()
        await vm.presentNew()
        vm.sheet?.body = "Yesterday:"

        vm.insertCursorPlaceholder()

        #expect(vm.sheet?.body == "Yesterday: cursor")
    }

    @Test("insertCursorPlaceholder on an empty body just inserts cursor")
    func insertCursorOnEmptyBody() async throws {
        let h = Harness()
        let vm = h.vm()
        await vm.presentNew()

        vm.insertCursorPlaceholder()

        #expect(vm.sheet?.body == "cursor")
    }

    // MARK: Delete

    @Test("delete removes the snippet locally and from storage")
    func deleteRemovesSnippet() async throws {
        let h = Harness()
        let vm = h.vm()
        await vm.load()
        await vm.presentNew()
        vm.sheet?.trigger = "/sig"
        vm.sheet?.body = "Kind regards"
        await vm.save()
        let snippet = vm.snippets[0]

        // Awaits the write deterministically (review M8) instead of busy-polling for it to land.
        await vm.delete(snippet).value

        #expect(vm.snippets.isEmpty)
        let remaining = await h.content.snippets.all()
        #expect(remaining.isEmpty)
    }

    // MARK: Toggle / empty

    @Test("sayPrefix reads and writes stylingSettings.snippetSayPrefix")
    func sayPrefixBindsToStylingSettings() {
        let h = Harness()
        let vm = h.vm()
        #expect(vm.sayPrefix == false)

        vm.sayPrefix = true

        #expect(h.settings.snippetSayPrefix == true)
    }

    @Test("isEmpty reflects whether there are any snippets")
    func isEmptyReflectsSnippets() async throws {
        let h = Harness()
        let vm = h.vm()
        await vm.load()
        #expect(vm.isEmpty == true)

        await vm.presentNew()
        vm.sheet?.trigger = "/sig"
        vm.sheet?.body = "Kind regards"
        await vm.save()

        #expect(vm.isEmpty == false)
    }
}
