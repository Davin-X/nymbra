import Foundation
import UserNotifications
import NymbraCore

/// The tab a notification is about, carried inside the notification itself.
///
/// A notification is a message to the future: it is posted now and clicked later,
/// by which time the dictionary it carries has been through another process.
/// `TabID` is a Swift value and does not survive that; its integer does.
///
/// Small enough to look like nothing, and worth its own type: it is the whole of
/// the click path that can be tested, because everything else about a click
/// happens in the notification daemon.
enum NotificationPayload {

    static let tabKey = "tab"

    static func userInfo(for tab: TabID) -> [String: Any] {
        [tabKey: tab.raw]
    }

    /// The tab a notification was about, or `nil` when it carries none.
    ///
    /// `AnyHashable` keys rather than `String`: this is the dictionary the
    /// notification daemon hands back, not one Nymbra made. A value that is not an
    /// integer has to mean "nothing to do" — not a wrong tab, and not a crash.
    static func tab(from userInfo: [AnyHashable: Any]) -> TabID? {
        guard let raw = userInfo[tabKey] as? Int else { return nil }
        return TabID(raw)
    }
}

/// What the notification system is told, and what a click on one of Nymbra's
/// notifications does.
///
/// `UNUserNotificationCenter` holds its delegate *weakly*, so this has to be owned
/// by something that lives as long as the application does: `AppController` is
/// that thing. A router nobody owns is one that has already been released by the
/// time somebody clicks.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {

    /// Bring a tab forward. Returns whether it was still there.
    ///
    /// A closure rather than a reference to `AppController`, so that the routing
    /// can be exercised without one. The two delegate methods below cannot be —
    /// a `UNNotification` and a `UNNotificationResponse` are made by the daemon —
    /// so the closures and `handle(userInfo:)` are the testable edge of this file.
    var focus: (TabID) -> Bool = { _ in false }

    /// A notification arrived while Nymbra was the active application.
    ///
    /// It must be shown. The system's default is to *suppress* a notification for
    /// whichever application is in front, and the case this feature exists for is
    /// precisely that one: Nymbra is in front and the command that finished is in
    /// a tab other than the one on screen. The rule that decided to speak has
    /// already run; this must not then hold its tongue, because a notification
    /// the settings promised and nobody ever sees is worse than none at all.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        handle(userInfo: response.notification.request.content.userInfo)
        completionHandler()
    }

    /// What a click meant, given what the notification carried.
    ///
    /// Separated from the delegate because a `UNNotificationResponse` cannot be
    /// constructed by anybody but the notification daemon. This is the only form
    /// of the click path a test can run — so it is the form the test runs, and the
    /// delegate method above is two lines that call it.
    @discardableResult
    func handle(userInfo: [AnyHashable: Any]) -> Bool {
        guard let tab = NotificationPayload.tab(from: userInfo) else { return false }
        return focus(tab)
    }
}
