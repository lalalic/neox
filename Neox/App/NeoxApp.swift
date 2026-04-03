import SwiftUI
import CopilotChat
import CopilotSDK
import UIKit
import UserNotifications

/// AppDelegate to reliably capture URL opens and push notifications on physical devices.
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var coordinator: AgentCoordinator?
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        // Set notification delegate
        UNUserNotificationCenter.current().delegate = self
        
        // Request notification permission and register for remote notifications
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            print("[AppDelegate] Notification permission: \(granted), error: \(error?.localizedDescription ?? "none")")
            if granted {
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        }
        return true
    }
    
    // MARK: - Push Notification Registration
    
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let tokenString = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("[AppDelegate] APNs device token: \(tokenString)")
        // Store token for relay registration
        UserDefaults.standard.set(tokenString, forKey: "apnsDeviceToken")
        // Notify relay via NotificationCenter
        NotificationCenter.default.post(name: .deviceTokenReceived, object: tokenString)
    }
    
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("[AppDelegate] Failed to register for remote notifications: \(error.localizedDescription)")
    }
    
    // MARK: - Handle incoming push while app is in foreground
    
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let userInfo = notification.request.content.userInfo
        print("[AppDelegate] Push received in foreground: \(userInfo)")
        // Show banner even when app is in foreground
        completionHandler([.banner, .sound, .badge])
    }
    
    // MARK: - Handle notification tap
    
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        print("[AppDelegate] Notification tapped: \(userInfo)")
        // Handle action from push (e.g., install build, open repo)
        if let action = userInfo["action"] as? String {
            NotificationCenter.default.post(name: .pushNotificationAction, object: nil, userInfo: ["action": action, "data": userInfo])
        }
        completionHandler()
    }
    
    // MARK: - Silent push (background wake)
    
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        print("[AppDelegate] Silent push received: \(userInfo)")
        // Use silent push to reconnect MCP if needed
        NotificationCenter.default.post(name: .silentPushReceived, object: nil, userInfo: userInfo as? [String: Any])
        completionHandler(.newData)
    }
    
    // MARK: - URL handling
    
    func application(_ application: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        print("[AppDelegate] open URL called: \(url)")
        NotificationCenter.default.post(name: .stripeDeepLink, object: url)
        return true
    }
    
    func application(_ app: UIApplication, open url: URL, sourceApplication: String?, annotation: Any) -> Bool {
        print("[AppDelegate] open URL (legacy) called: \(url)")
        NotificationCenter.default.post(name: .stripeDeepLink, object: url)
        return true
    }
}

extension Notification.Name {
    static let stripeDeepLink = Notification.Name("stripeDeepLink")
    static let deviceTokenReceived = Notification.Name("deviceTokenReceived")
    static let pushNotificationAction = Notification.Name("pushNotificationAction")
    static let silentPushReceived = Notification.Name("silentPushReceived")
}

@main
struct NeoxApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var coordinator = AgentCoordinator()
    @Environment(\.scenePhase) private var scenePhase
    
    init() {
        // Register BGTask handlers before app finishes launching
        PlanExecutor.shared.registerBGTasks()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(coordinator)
                .task {
                    let vm = coordinator.createChatViewModel()
                    
                    // Configure PlanExecutor with relay settings and plan store
                    PlanExecutor.shared.configure(
                        planStore: vm.planStore,
                        relayHost: coordinator.relayHost,
                        relayPort: coordinator.relayPort
                    )
                    PlanExecutor.shared.scheduleNextCheck()
                    
                    startAppAgent(coordinator: coordinator)
                }
                .onOpenURL { url in
                    print("[NeoxApp] onOpenURL: \(url)")
                    handleDeepLink(url)
                }
                .onReceive(NotificationCenter.default.publisher(for: .stripeDeepLink)) { note in
                    if let url = note.object as? URL {
                        print("[NeoxApp] stripeDeepLink notification: \(url)")
                        handleDeepLink(url)
                    }
                }
                .onChange(of: scenePhase) { newPhase in
                    if newPhase == .active {
                        checkPendingStripePayment()
                    }
                }
        }
    }
    
    // MARK: - Deep Link Handling
    
    private func handleDeepLink(_ url: URL) {
        // Handle neox://stripe/success?session_id=cs_test_...
        guard url.scheme == "neox", url.host == "stripe" else { return }
        
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard url.path == "/success" || url.path == "success",
              let sessionId = components?.queryItems?.first(where: { $0.name == "session_id" })?.value,
              !sessionId.isEmpty else {
            print("[NeoxApp] Stripe callback missing session_id: \(url)")
            return
        }
        
        print("[NeoxApp] Stripe payment callback received, session: \(sessionId)")
        
        // Clear pending checkout flag since deep link worked
        UserDefaults.standard.removeObject(forKey: "pendingStripeCheckoutRef")
        
        // Build relay HTTP URL (WS port + 1)
        let httpPort = coordinator.relayPort + 1
        let relayURL = "http://\(coordinator.relayHost):\(httpPort)/stripe/verify"
        
        Task {
            await verifyStripeSession(body: ["session_id": sessionId], relayURL: relayURL)
        }
    }
    
    // MARK: - Foreground-Resume Payment Check
    
    /// When app returns to foreground, check if there's a pending Stripe checkout to verify.
    private func checkPendingStripePayment() {
        guard let refId = UserDefaults.standard.string(forKey: "pendingStripeCheckoutRef"),
              !refId.isEmpty else { return }
        
        print("[NeoxApp] Foreground resume — checking pending Stripe payment for ref: \(refId)")
        
        let httpPort = coordinator.relayPort + 1
        let relayURL = "http://\(coordinator.relayHost):\(httpPort)/stripe/verify"
        
        Task {
            let success = await verifyStripeSession(body: ["client_reference_id": refId], relayURL: relayURL)
            if success {
                // Payment verified, clear pending flag
                UserDefaults.standard.removeObject(forKey: "pendingStripeCheckoutRef")
                print("[NeoxApp] Pending Stripe payment verified and cleared")
            }
            // If not yet paid, keep the flag — will retry on next foreground
        }
    }
    
    @discardableResult
    private func verifyStripeSession(body: [String: String], relayURL: String) async -> Bool {
        guard let url = URL(string: relayURL) else {
            print("[NeoxApp] Invalid relay URL: \(relayURL)")
            return false
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            
            guard httpResponse.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ok = json["ok"] as? Bool, ok,
                  let sessionId = json["sessionId"] as? String,
                  let productId = json["productId"] as? String else {
                let responseBody = String(data: data, encoding: .utf8) ?? "(empty)"
                print("[NeoxApp] Stripe verify failed (HTTP \(httpResponse.statusCode)): \(responseBody)")
                return false
            }

            let creditedKey = "creditedStripeSessions"
            var creditedSessions = Set(UserDefaults.standard.stringArray(forKey: creditedKey) ?? [])
            if creditedSessions.contains(sessionId) {
                print("[NeoxApp] Stripe session already credited locally: \(sessionId)")
                return true
            }
            
            let credits = PaymentManager.creditValues[productId] ?? 0
            if credits > 0 {
                await MainActor.run {
                    coordinator.chatViewModel?.usageTracker.addCredits(credits)
                    NotificationCenter.default.post(
                        name: .stripeCreditsGranted,
                        object: nil,
                        userInfo: ["credits": credits, "productId": productId]
                    )
                }
                creditedSessions.insert(sessionId)
                UserDefaults.standard.set(Array(creditedSessions), forKey: creditedKey)
                print("[NeoxApp] Stripe payment verified! Added $\(String(format: "%.2f", credits)) credits for \(productId)")
                return true
            } else {
                print("[NeoxApp] Unknown productId from Stripe verify: \(productId)")
                return false
            }
        } catch {
            print("[NeoxApp] Stripe verify request failed: \(error.localizedDescription)")
            return false
        }
    }
    
    private func startAppAgent(coordinator: AgentCoordinator) {
        let setup = AppAgentSetup.shared
        setup.coordinator = coordinator
        do {
            try setup.start()
        } catch {
            setup.startError = error.localizedDescription
            print("[NeoxApp] AppAgent MCP server failed to start: \(error)")
        }
        
        // On device: connect to bridge server for reverse MCP (when enabled in settings)
        #if !targetEnvironment(simulator)
        if coordinator.useDevServer {
            setup.connectBridge(url: "ws://10.0.0.101:\(coordinator.devServerPort)/ws")
        }
        #endif
    }
}
