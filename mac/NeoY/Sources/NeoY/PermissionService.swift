import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation
import UserNotifications

enum NeoYPermissionKind: String, Codable, CaseIterable, Sendable {
    case accessibility
    case screenRecording = "screen-recording"
    case camera
    case microphone
    case notifications
    case localNetwork = "local-network"
}


extension NeoYPermissionKind {
    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .notifications: "Notifications"
        case .localNetwork: "Local Network"
        }
    }

    var dependentFeatures: [String] {
        switch self {
        case .accessibility: ["Computer Use", "Demo semantic targeting"]
        case .screenRecording: ["Computer Use screenshots", "Demo recording"]
        case .camera: ["Capture Tour"]
        case .microphone: ["Capture Tour audio"]
        case .notifications: ["Notifications"]
        case .localNetwork: ["Phone discovery", "local integrations"]
        }
    }
}

enum NeoYPermissionState: String, Codable, Sendable {
    case authorized
    case denied
    case notDetermined = "not-determined"
    case restricted
    case runtimeProbe = "runtime-probe"
}

struct NeoYPermissionStatus: Codable, Equatable, Sendable {
    let kind: NeoYPermissionKind
    let state: NeoYPermissionState
    let humanApprovalRequired: Bool
    let guidance: String
}

enum NeoYPermissionService {
    static func snapshot() async -> [NeoYPermissionStatus] {
        let notificationState = await notificationPermissionState()
        return [
            .init(
                kind: .accessibility,
                state: AXIsProcessTrusted() ? .authorized : .denied,
                humanApprovalRequired: true,
                guidance: "Grant NeoY in System Settings > Privacy & Security > Accessibility."
            ),
            .init(
                kind: .screenRecording,
                state: CGPreflightScreenCaptureAccess() ? .authorized : .denied,
                humanApprovalRequired: true,
                guidance: "Grant NeoY in System Settings > Privacy & Security > Screen & System Audio Recording."
            ),
            .init(
                kind: .camera,
                state: state(AVCaptureDevice.authorizationStatus(for: .video)),
                humanApprovalRequired: true,
                guidance: "Camera permission is requested by macOS when NeoY first needs camera capture."
            ),
            .init(
                kind: .microphone,
                state: state(AVCaptureDevice.authorizationStatus(for: .audio)),
                humanApprovalRequired: true,
                guidance: "Microphone permission is requested by macOS when NeoY first needs audio capture."
            ),
            .init(
                kind: .notifications,
                state: notificationState,
                humanApprovalRequired: true,
                guidance: "Notification permission is controlled by macOS System Settings."
            ),
            .init(
                kind: .localNetwork,
                state: .runtimeProbe,
                humanApprovalRequired: true,
                guidance: "macOS has no reliable read-only Local Network permission API; NeoY reports connectivity through its Bonjour/runtime status."
            ),
        ]
    }

    @MainActor
    static func open(_ kind: NeoYPermissionKind) -> Bool {
        let suffix: String
        switch kind {
        case .accessibility: suffix = "Privacy_Accessibility"
        case .screenRecording: suffix = "Privacy_ScreenCapture"
        case .camera: suffix = "Privacy_Camera"
        case .microphone: suffix = "Privacy_Microphone"
        case .notifications:
            guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return false }
            return NSWorkspace.shared.open(url)
        case .localNetwork: suffix = "Privacy_LocalNetwork"
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(suffix)") else { return false }
        return NSWorkspace.shared.open(url)
    }

    private static func state(_ value: AVAuthorizationStatus) -> NeoYPermissionState {
        switch value {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .restricted
        }
    }

    private static func notificationPermissionState() async -> NeoYPermissionState {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let state: NeoYPermissionState
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral: state = .authorized
                case .denied: state = .denied
                case .notDetermined: state = .notDetermined
                @unknown default: state = .restricted
                }
                continuation.resume(returning: state)
            }
        }
    }
}
