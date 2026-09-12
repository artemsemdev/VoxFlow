import AppKit
import SwiftUI

/// Dock-icon drops and Finder "Open With" (design MW-06: "drop on Dock icon").
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var quitCoordinator: QuitCoordinator?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !LaunchEnvironment.isRunningTests() else { return .terminateNow }
        if quitCoordinator?.allowsTermination == true { return .terminateNow }
        if quitCoordinator == nil {
            let services = AppServices.shared
            quitCoordinator = QuitCoordinator(snapshot: {
                let pendingDictation = await services.dictationController.beginTermination()
                await services.queue.setTerminationPending(true)
                let items = await services.queue.items
                let pendingExport = items.contains { item in
                    if case .done = item.status {
                        return services.exports.url(for: item.id) == nil
                    }
                    return false
                }
                let running = await services.queue.isRunning || pendingExport
                let item = items.first {
                    switch $0.status { case .running, .loadingModel: true; default: false }
                }
                let progress: Double? = if case .running(let value)? = item?.status { value } else { nil }
                return QuitActivity(queueRunning: running, fileName: item?.url.lastPathComponent,
                                    progress: progress, dictation: await services.dictationController.state,
                                    pendingDictationWork: pendingDictation,
                                    hasUnsavedTranscript: items.contains { services.exports.error(for: $0.id) != nil },
                                    etaText: item.flatMap { services.filesViewModel.etaText(for: $0) })
            }, present: QuitCoordinator.present, finish: {
                // Keep the app's menu bar and event loop alive until all current work is durable.
                async let dictation: Void = services.dictationController.finishForTermination()
                await services.queue.waitUntilIdle()
                let exported = await services.exports.waitForExports(of: services.queue.items)
                await dictation
                if !exported {
                    services.navigation.page = .files
                    services.navigation.requestMainWindow = true
                }
                return exported
            }, resume: {
                await services.dictationController.cancelTermination()
                await services.queue.setTerminationPending(false)
            }, quit: { sender.terminate(nil) })
        }
        Task { await quitCoordinator?.request() }
        return .terminateCancel
    }

    /// Starts the dictation loop exactly once: `dictation.start()` begins mirroring controller state,
    /// `flowBar.bind(to:)` shows/hides the HUD off that state, `fnMonitor.start()` arms the global
    /// fn/esc/any-key monitors (design 3e — needs Accessibility trust to see events at all).
    ///
    /// None of that (nor `historyService.ready()`) runs under the XCTest host: the test process must
    /// never open the mic, install global fn/esc monitors or touch the Keychain (#143) just because
    /// it launched the app to host its tests.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // M-2: gates the onboarding-routing block too, not just dictation/monitor/`ready()` above it
        // — without this, an XCTest run on a machine where onboarding was never completed closes the
        // test host's main window and opens the onboarding window (running `TryItStepView.onAppear`
        // → `beginTryIt()`) under the test process. Harmless today (no mic/Keychain/dictation under
        // tests either way), but it contradicted the stated "nothing onboarding-related runs under
        // XCTest" rule.
        if LaunchEnvironment.isRunningTests() == false {
            AppServices.shared.dictation.start()
            // Phase 5: warm the style LLM into memory now (Metal shaders + weights) so the first
            // dictation after launch doesn't pay that cost — `StyleModelLoader.warmUp()` is a no-op
            // once already loaded, and never blocks dictation itself (`.utility`, unawaited here).
            Task(priority: .utility) { await AppServices.shared.styleModelLoader.warmUp() }
            AppServices.shared.flowBar.bind(to: AppServices.shared.dictation)
            AppServices.shared.fnMonitor.start()
            // Electron enables its Accessibility tree asynchronously. Prepare it when the user
            // switches apps, before a later Fn capture needs the focused editor. One observer
            // lasts for the application lifetime; test hosts never register it.
            _ = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { _ in
                Task { @MainActor in AXTextTarget.prepareFocusedApplication() }
            }
            AXTextTarget.prepareFocusedApplication()
            // MB-03/MB-04 (ruling 8): never starts under XCTest, same reasoning as everything else
            // in this block — a test run must not touch the real Notification Center either.
            AppServices.shared.notifications.start()
            // `HistoryService` opens lazily (Keychain access deferred to first use) — run that open
            // once here at a real launch so retention (design §5) runs at launch as the spec says,
            // rather than waiting for the first History read/write to trigger it implicitly. C1:
            // chained straight into `statsService.refresh()` so Home/the menu bar show real numbers
            // the moment the store's open resolves, instead of only after someone navigates to Home.
            Task {
                await AppServices.shared.historyService.ready()
                await AppServices.shared.statsService.refresh()
            }
            // C1: `ContentService` also opens lazily, and was previously only ever opened by a
            // Dictionary/Snippets/Styles page (or by `noteUses` *after* the first dictation) —
            // meaning the first dictation of every cold launch ignored the dictionary, snippets and
            // per-app overrides. Opening it here, in parallel with history, means its snapshot boxes
            // are already populated (or racing to be) before fn is ever pressed.
            Task { await AppServices.shared.contentService.ready() }

            // Phase 6 (ST-06): starts the real MCP server at launch when the user already had it
            // enabled last session. A failure here (ports 7331–7340 all busy) is silently logged,
            // not surfaced — there's no window guaranteed to be on screen at this point to show it
            // in; `mcpViewModel.refresh()` (Settings › MCP Server's `.task`) re-syncs the toggle
            // with reality the next time that page opens, same as `GeneralViewModel`'s own I3.
            if AppServices.shared.mcpSettings.enabled {
                Task { try? await AppServices.shared.mcpServerService.start() }
            }

            // First launch (or onboarding never finished): show it instead of the main window —
            // closing whatever SwiftUI already opened for `MainWindowID.main` so the two don't both
            // appear.
            if !AppServices.shared.onboardingState.completed {
                NSApp.windows.first { $0.identifier?.rawValue == MainWindowID.main }?.close()
                // M-1: `requestOnboarding` is consumed by `.onChange` on the main `Window` scene, which
                // SwiftUI attaches while building the scene graph — that may not have happened yet at
                // `applicationDidFinishLaunching` (this runs from `NSApplicationDelegateAdaptor`, which
                // itself fires from within that same launch sequence). Setting it a runloop turn later
                // gives the scene graph a turn to finish installing its observers first, so the flag is
                // never set before anything is watching it.
                Task { @MainActor in
                    AppServices.shared.navigation.requestOnboarding = true
                }
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !LaunchEnvironment.isRunningTests() else { return }
        AppServices.shared.fnMonitor.refreshEventSource()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !LaunchEnvironment.isRunningTests() else { return }
        Task { @MainActor in
            // Navigate first so the Files page (and its running-row UI) is what the user sees when
            // the window comes forward, rather than whatever page happened to be selected before.
            AppServices.shared.navigation.page = .files
            NSApp.activate(ignoringOtherApps: true)
            // No `@Environment(\.openWindow)` exists on an `NSApplicationDelegate` — `VoxFlowApp`
            // itself owns that action, so raising a not-currently-visible window is a flag it
            // observes rather than a call made directly from here.
            let mainWindowVisible = NSApp.windows.contains { $0.isVisible && $0.identifier?.rawValue == MainWindowID.main }
            if !mainWindowVisible {
                AppServices.shared.navigation.requestMainWindow = true
            }
            await AppServices.shared.queue.add(urls)
            await AppServices.shared.queue.start()
        }
    }

    /// VoxFlow is a menu bar app (`MenuBarExtra`) as well as a window app: closing the last window
    /// should never quit it out from under the menu bar item or an in-progress background export.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
