@preconcurrency import UIKit
@preconcurrency import UserNotifications

extension Notification.Name {
    static let markcutReviewNotificationTapped = Notification.Name("markcutReviewNotificationTapped")
}

final class MarkcutReviewNotificationDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        guard response.notification.request.content.userInfo["reviewRequestId"] as? String != nil else { return }
        Task { @MainActor in
            NotificationCenter.default.post(name: .markcutReviewNotificationTapped, object: nil)
        }
    }
}
