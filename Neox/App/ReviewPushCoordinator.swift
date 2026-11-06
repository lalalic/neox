import Foundation
import UIKit
import UserNotifications

/// Neo Master persists review requests; APNs is only a wake-up notification.
/// The phone mirrors pending requests and emits human decisions via Events MCP.
@MainActor
final class ReviewPushCoordinator {
    static let shared = ReviewPushCoordinator()

    static func apnsEnvironment(from provisioning: Data?) -> String {
        guard let provisioning else { return "production" } // App Store / TestFlight
        // CMS profile contains the embedded XML entitlement plist. Only its
        // non-secret aps-environment string is read; no signature is replaced.
        let text = String(decoding: provisioning, as: UTF8.self)
        guard let range = text.range(of: "<key>aps-environment</key>") else { return "production" }
        let value = text[range.upperBound...].prefix(200)
        return value.contains("<string>development</string>") ? "sandbox" : "production"
    }
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
        // A Release-built app installed via Xcode can carry a development
        // entitlement. Infer APNs environment from its signed provisioning
        // profile, not from the DEBUG compilation flag.
        let profile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
            .flatMap { try? Data(contentsOf: $0) }
        let environment = Self.apnsEnvironment(from: profile)
        do {
            try await master.registerAPNsDevice(deviceID: deviceID, token: token, environment: environment)
            lastRegistration = (token, address)
        } catch {
            // No token is stored in UserDefaults or logs. Try again on next
            // foreground connection / authenticated Master status check.
        }
    }

    func syncPending() async {
        guard master.hasCredential, master.hasConfiguredAddress else { return }
        do {
            let requests = try await master.pendingMarkcutReviews()
            // Master returns newest-first; local accept inserts at index 0.
            // Import oldest-first so the newest revision remains the current
            // request for each video group (older revisions read-only).
            for request in requests.reversed() {
                _ = MarkcutReviewInboxStore.shared.accept(request, notify: false)
            }
        } catch {
            // A missed APNs or temporarily unreachable Master is retried on
            // next foreground / Review Inbox entry, without losing local rows.
        }
    }

    func complete(_ id: String) async {
        // The human event has already been accepted by Events MCP. If this
        // acknowledgement fails, the local dedup tombstone prevents replay.
        try? await master.completeMarkcutReview(id)
    }

    static func reviewRequestID(_ userInfo: [AnyHashable: Any]) -> String? {
        guard let id = userInfo["neoReviewRequestId"] as? String,
              UUID(uuidString: id) != nil else { return nil }
        return id
    }

    static func decodeReview(_ userInfo: [AnyHashable: Any]) -> MarkcutReviewRequest? {
        guard let raw = userInfo["neoReview"] as? [String: Any],
              JSONSerialization.isValidJSONObject(raw),
              let bytes = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        return try? JSONDecoder().decode(MarkcutReviewRequest.self, from: bytes)
    }


    /// Import delivered APNs alerts even when the user opens Neo from its icon
    /// instead of tapping the notification. Apple does not promise background
    /// execution for ordinary alert pushes.
    func clearDeliveredReview(_ id: String) async {
        let matching: [String] = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
                let ids = notifications.filter { note in
                    if note.request.content.userInfo["neoReviewRequestId"] as? String == id { return true }
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
        await syncPending()
    }
}
