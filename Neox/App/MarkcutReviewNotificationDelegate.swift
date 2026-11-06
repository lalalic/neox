@preconcurrency import UIKit
@preconcurrency import UserNotifications

extension Notification.Name {
    static let markcutReviewNotificationTapped = Notification.Name("markcutReviewNotificationTapped")
}

final class MarkcutReviewNotificationDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Task { @MainActor in
            // The request authorization controls banners; device registration
            // is required independently to obtain an APNs device token.
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
            application.registerForRemoteNotifications()
            await ReviewPushCoordinator.shared.recoverDeliveredNotifications()
        }
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        Task { @MainActor in await ReviewPushCoordinator.shared.receivedDeviceToken(token) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Retry on the next active scene, without retaining stale device tokens.
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // The APNs payload contains only the request UUID, never the review template.
        if let id = notification.request.content.userInfo["neoReviewRequestId"] as? String,
           UUID(uuidString: id) != nil {
            await ReviewPushCoordinator.shared.syncPending()
        }
        return [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let isLocal = info["reviewRequestId"] as? String != nil
        let isRemote = (info["neoReviewRequestId"] as? String)
            .flatMap(UUID.init(uuidString:)) != nil
        guard isLocal || isRemote else { return }
        if isRemote { await ReviewPushCoordinator.shared.syncPending() }
        await MainActor.run {
            NotificationCenter.default.post(name: .markcutReviewNotificationTapped, object: nil)
        }
    }
}
