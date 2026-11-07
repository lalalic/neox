import Foundation
import UIKit
import UserNotifications
import Combine

/// Neo Master persists review requests; APNs is only a wake-up notification.
/// The phone mirrors previews and pending reviews; APNs is a pointer, not the inbox.
@MainActor
final class ReviewPushCoordinator: ObservableObject {
    static let shared = ReviewPushCoordinator()
    @Published private(set) var tappedRequestID: String?
    @Published private(set) var syncError: String?

    func notificationTapped(_ id: String) { tappedRequestID = id }

    static func apnsEnvironment(from provisioning: Data?) -> String {
        guard let provisioning else { return "production" } // App Store / TestFlight
        // CMS profile contains the embedded XML entitlement plist. Only its
        // non-secret aps-environment string is read; no signature is replaced.
        let text = String(decoding: provisioning, as: UTF8.self)
        guard let range = text.range(of: "<key>aps-environment</key>") else { return "production" }
        let value = text[range.upperBound...].prefix(200)
        return value.contains("<string>development</string>") ? "sandbox" : "production"
    }
    private var deviceToken: String?
    private var registrationInFlight = false
    private var lastRegistration: (token: String, master: String)?

    func receivedDeviceToken(_ data: Data) async {
        deviceToken = data.map { String(format: "%02x", $0) }.joined()
        await retryRegistration()
    }

    func retryRegistration() async {
        // Re-read the latest Master Access Code; first pairing may happen after
        // this coordinator was initialized when the app launched.
        let master = RemoteMCPClient()
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
        let master = RemoteMCPClient()
        guard master.hasCredential, master.hasConfiguredAddress else {
            syncError = "Connect to Neo Master with its Master Access Code to load previews."
            return
        }
        do {
            let requests = try await master.pendingMarkcutReviews()
            // Import oldest-first so newer revisions stay current. This also
            // includes read-only text-mode previews with no human decision.
            for request in requests.reversed() {
                _ = MarkcutReviewInboxStore.shared.accept(request, notify: false)
            }
            syncError = nil
        } catch {
            // Never turn an HTTP/auth/decoding failure into a misleading empty
            // inbox. The user can retry from the Inbox or on next foreground.
            syncError = "Cannot load Neo Master previews: " + error.localizedDescription
        }
    }

    func complete(_ id: String) async {
        let master = RemoteMCPClient()
        // The human event has already been accepted by Events MCP. If this
        // acknowledgement fails, the local dedup tombstone prevents replay.
        try? await master.completeMarkcutReview(id)
    }

    static func reviewRequestID(_ userInfo: [AnyHashable: Any]) -> String? {
        guard let id = userInfo["neoReviewRequestId"] as? String,
              UUID(uuidString: id) != nil else { return nil }
        return id
    }

    /// Import delivered APNs alerts even when the user opens Neo from its icon
    /// instead of tapping the notification. Apple does not promise background
    /// execution for ordinary alert pushes.
    func clearDeliveredReview(_ id: String) async {
        let matching: [String] = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
                let ids = notifications.filter { notification in
                    notification.request.content.userInfo["neoReviewRequestId"] as? String == id
                }.map { $0.request.identifier }
                continuation.resume(returning: ids)
            }
        }
        if !matching.isEmpty {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: matching)
        }
    }

    /// APNs may be missed or cleared, so the authenticated Master inbox is
    /// authoritative on every app foreground, not only notification taps.
    func recoverDeliveredNotifications() async {
        await syncPending()
    }
}
