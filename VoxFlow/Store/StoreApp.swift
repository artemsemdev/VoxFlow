import AppKit
import SwiftUI

#if APP_STORE
@main
#endif
struct StoreApp: App {
    @NSApplicationDelegateAdaptor(StoreAppDelegate.self) private var delegate
    var body: some Scene {
        Window("VoxFlow", id: "store-main") {
            StoreWindow().environment(StoreServices.shared)
        }
        .defaultSize(width: 1280, height: 800)
        .commands { CommandGroup(replacing: .newItem) { } }
    }
}

/// Reuses the existing finish/save/quit coordinator without constructing the full app's services.
final class StoreAppDelegate: NSObject, NSApplicationDelegate {
    private var quit: QuitCoordinator?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quit?.allowsTermination == true { return .terminateNow }
        if quit == nil {
            let services = StoreServices.shared
            quit = QuitCoordinator(snapshot: {
                let pending = await services.dictation.beginTermination()
                await services.queue.setTerminationPending(true)
                let items = await services.queue.items
                let pendingExport = items.contains {
                    if case .done = $0.status { return services.exports.url(for: $0.id) == nil }
                    return false
                }
                return QuitActivity(queueRunning: await services.queue.isRunning || pendingExport,
                    fileName: nil, progress: nil, dictation: await services.dictation.state,
                    pendingDictationWork: pending,
                    hasUnsavedTranscript: services.draft.saveError != nil || items.contains { services.exports.error(for: $0.id) != nil }, etaText: nil)
            }, present: QuitCoordinator.present, finish: {
                await services.dictation.finishForTermination()
                await services.queue.waitUntilIdle()
                let exported = await services.exports.waitForExports(of: services.queue.items)
                services.draft.save()
                return exported && services.draft.saveError == nil
            }, resume: {
                await services.dictation.cancelTermination()
                await services.queue.setTerminationPending(false)
            }, shutdown: {
                await services.dictation.escape()
                for item in await services.queue.items { await services.queue.cancel(id: item.id) }
                await services.queue.waitUntilIdle()
                await services.engine.shutdown()
                services.releaseInputAccess()
            }, quit: { sender.terminate(nil) })
        }
        Task { await quit?.request() }
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
