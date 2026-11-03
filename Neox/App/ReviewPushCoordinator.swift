import Foundation
import UIKit
import UserNotifications

/// APNs is a transport, not the owner of the review lifecycle. The phone alone
/// owns pending requests and submits feedback to the original ChatGPT thread.
@MainActor
final class ReviewPushCoordinator {
    static let shared = ReviewPushCoordinator()
    private let master = RemoteMCPClient()
    private var deviceToken: String?
    private var registrationInFlight = false
    private var lastRegistration: (token: String, master: String)?

    func receivedDeviceToken(_ data: Data) async {
        deviceToken = data.map { String(format: "%02x", $0) }.joined()
        await retryRegistration()
    }

    func retryRegistration() async {
        guard let token = deviceToken, !registrationInFlight,
              master.hasCredential, master.hasConfiguredAddress else { return }
        let address = master.endpoint
        guard lastRegistration?.token != token || lastRegistration?.master != address else { return }
        guard let deviceID = UIDevice.current.identifierForVendor?.uuidString else { return }
        registrationInFlight = true
        defer { registrationInFlight = false }
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        do {
            try await master.registerAPNsDevice(deviceID: deviceID, token: token, environment: environment)
            lastRegistration = (token, address)
        } catch {
            // No token is stored in UserDefaults or logs. Try again on next
            // foreground connection / authenticated Master status check.
        }
    }

    static func decodeReview(_ userInfo: [AnyHashable: Any]) -> MarkcutReviewRequest? {
        guard let raw = userInfo["neoReview"] as? [String: Any],
              JSONSerialization.isValidJSONObject(raw),
              let bytes = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        return try? JSONDecoder().decode(MarkcutReviewRequest.self, from: bytes)
    }

    @discardableResult
    func receive(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let request = Self.decodeReview(userInfo) else { return false }
        let inbox = MarkcutReviewInboxStore.shared
        let inserted = inbox.accept(request, notify: false)
        return inserted || inbox.request(id: request.id) != nil
    }

    /// Import delivered APNs alerts even when the user opens Neo from its icon
    /// instead of tapping the notification. Apple does not promise background
    /// execution for ordinary alert pushes.
    func clearDeliveredReview(_ id: String) async {
        let matching: [String] = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
                let ids = notifications.filter { note in
                    guard let raw = note.request.content.userInfo["neoReview"] as? [String: Any] else { return false }
                    return raw["id"] as? String == id
                }.map { $0.request.identifier }
                continuation.resume(returning: ids)
            }
        }
        if !matching.isEmpty {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: matching)
        }
    }

    func recoverDeliveredNotifications() async {
        // Move only Sendable Data across the notification-center callback;
        // UNNotification is a mutable, non-Sendable Objective-C object.
        let payloads: [Data] = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
                let blobs = notifications.compactMap { notification -> Data? in
                    guard let payload = notification.request.content.userInfo["neoReview"] as? [String: Any],
                          JSONSerialization.isValidJSONObject(payload) else { return nil }
                    return try? JSONSerialization.data(withJSONObject: payload)
                }
                continuation.resume(returning: blobs)
            }
        }
        for payload in payloads {
            if let request = try? JSONDecoder().decode(MarkcutReviewRequest.self, from: payload) {
                _ = MarkcutReviewInboxStore.shared.accept(request, notify: false)
            }
        }
    }
}
