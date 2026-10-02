import Foundation
import UserNotifications

enum EventTools {
    static func tools() -> [ToolDefinition] {
        [ToolDefinition(
            name: "event.iphone.notify",
            description: "Deliver one important desktop-runtime event as a local NeoX notification. Intended for blocked, failure, or completed events after NeoY policy filtering.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "kind": .object(["type": .string("string")]),
                    "title": .object(["type": .string("string")]),
                    "body": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("kind"), .string("title"), .string("body")]),
            ])
        ) { arguments in
            guard case .object(let values) = arguments,
                  case .string(let kind)? = values["kind"],
                  case .string(let title)? = values["title"],
                  case .string(let body)? = values["body"],
                  ["blocked", "failure", "completed"].contains(kind),
                  !title.isEmpty, !body.isEmpty else {
                return "Error: kind (blocked|failure|completed), title, and body are required"
            }

            let center = UNUserNotificationCenter.current()
            var permission = await notificationPermission(center)
            if permission == .notDetermined {
                _ = try? await requestAuthorization(center)
                permission = await notificationPermission(center)
            }
            guard permission == .authorized else {
                return #"{"delivered":false,"reason":"notifications_not_authorized"}"#
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = kind == "completed" ? nil : .default
            content.userInfo = ["kind": kind, "source": "NeoY"]
            let request = UNNotificationRequest(
                identifier: "neoy.\(kind).\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            do {
                try await add(request, center: center)
                return #"{"delivered":true}"#
            } catch {
                return "Error: notification delivery failed: \(error.localizedDescription)"
            }
        }]
    }

    private enum NotificationPermission: Sendable {
        case authorized
        case notDetermined
        case denied
    }

    private static func notificationPermission(_ center: UNUserNotificationCenter) async -> NotificationPermission {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                let value: NotificationPermission
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral: value = .authorized
                case .notDetermined: value = .notDetermined
                case .denied: value = .denied
                @unknown default: value = .denied
                }
                continuation.resume(returning: value)
            }
        }
    }

    private static func requestAuthorization(_ center: UNUserNotificationCenter) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: granted) }
            }
        }
    }

    private static func add(_ request: UNNotificationRequest, center: UNUserNotificationCenter) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }
}
