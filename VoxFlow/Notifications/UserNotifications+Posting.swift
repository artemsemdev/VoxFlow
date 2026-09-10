import Synchronization
import UserNotifications

/// Production `NotificationPosting`: `UNUserNotificationCenter.current()`, never stored as a
/// property (same reason `SystemPasteboard`/`FinderRevealer` call `.general`/`.shared` fresh inside
/// each method instead of holding one — the AppKit/Foundation singleton itself isn't `Sendable`,
/// only the call site needs to touch it).
///
/// `final class … : Sendable` (not `@unchecked Sendable`) is sound here because the only stored
/// state is `routes` (`Mutex`-protected) and `onRoute` (a `@Sendable` closure) — nothing mutable
/// escapes without going through the mutex.
final class UserNotificationsPoster: NSObject, NotificationPosting, Sendable {
    /// `UNNotificationRequest.identifier` → the route it was posted with, so `didReceive response:`
    /// (which only gets the identifier back) can resolve what a click should do. Entries are never
    /// removed — the delivered-notification list is small and process-lifetime, and removing on
    /// click would race a second, slower-to-arrive click on the same notification.
    private let routes = Mutex<[String: NotificationRoute]>([:])
    /// Delivers a resolved route back to the app — production wiring (`AppServices.live()`) hops to
    /// the main actor and calls into `NotificationCoordinator.handleRoute(_:)`; never touched
    /// directly here, so this poster stays `Navigation`/`FilesViewModel`-agnostic.
    private let onRoute: @Sendable (NotificationRoute) -> Void

    init(onRoute: @escaping @Sendable (NotificationRoute) -> Void) {
        self.onRoute = onRoute
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// `.alert` + `.sound` only (ruling 8) — no `.badge`, VoxFlow's Dock icon carries no count.
    func authorize() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func post(_ notification: AppNotification) {
        routes.withLock { $0[notification.id] = notification.route }
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        let request = UNNotificationRequest(identifier: notification.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

/// `UNUserNotificationCenterDelegate`'s callbacks are not main-actor-isolated (the framework
/// predates Swift concurrency and carries no `@MainActor` annotation) and can arrive on any thread
/// — both methods below stay `nonisolated` (the default) and touch only `routes` (mutex-protected)
/// and `onRoute` (a `@Sendable` closure that does its own main-actor hop), never
/// `nonisolated(unsafe)`/`assumeIsolated`.
extension UserNotificationsPoster: UNUserNotificationCenterDelegate {
    /// VoxFlow only ever posts while the main window isn't frontmost (ruling 8), but showing the
    /// banner even if the app *is* frontmost by the time it's actually presented is harmless — the
    /// alternative (silently swallowing it) would be a worse surprise.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let route = routes.withLock({ $0[response.notification.request.identifier] }) else { return }
        onRoute(route)
    }
}
