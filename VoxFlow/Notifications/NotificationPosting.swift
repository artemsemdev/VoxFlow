import Foundation

/// Where a notification click should take the user (design MB-03/MB-04) — `NotificationCoordinator`
/// decides the route when it posts; whoever implements `NotificationPosting` (`UserNotificationsPoster`
/// in production) is only responsible for handing it back unchanged when the user clicks.
enum NotificationRoute: Sendable, Equatable {
    /// MB-03 "{Model} installed. Ready to use offline." → Settings › Models.
    case settingsModels
    /// MB-04 "{file} transcribed …" → the Files result for that queue row.
    case filesResult(itemID: UUID)
}

/// One completion notification (design MB-03, MB-04) — title is always "VoxFlow" (ruling 8), so
/// callers never have to repeat it.
struct AppNotification: Sendable, Equatable {
    let id: String
    let title: String
    let body: String
    let route: NotificationRoute

    init(id: String = UUID().uuidString, body: String, route: NotificationRoute) {
        self.id = id
        self.title = "VoxFlow"
        self.body = body
        self.route = route
    }
}

/// Posts completion notifications, behind a protocol so `NotificationCoordinatorTests` can fake it
/// without touching the real Notification Center (or granting it Accessibility-style permission
/// during a test run). `authorize()` is requested lazily, on the first completion that actually
/// needs to post (ruling 8) — never at launch, and never for a completion that never posts because
/// the main window is frontmost.
protocol NotificationPosting: Sendable {
    /// Requests `.alert` + `.sound` authorization; the result is the caller's to cache (this
    /// protocol makes no promise about repeat calls being cheap).
    func authorize() async -> Bool
    /// Fire-and-forget: production posts to `UNUserNotificationCenter` and returns immediately: a
    /// click is delivered later, out of band, through however the poster was told to route it.
    func post(_ notification: AppNotification)
}
