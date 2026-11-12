import Foundation
import CryptoKit

/// A generic Neo Master mobile device registry and APNs transport. Review
/// requests and business decisions never enter this service.
enum NeoYMobileDeviceNotifications {
    static let registration = "/mobile/device/register"
    static let notify = "/mobile/notify"
    static let actions = [("POST", registration), ("POST", notify)]
    private static let store = DeviceStore()

    nonisolated static func allowed(path: String, isLocal: Bool,
                                    headers: [String: String], masterAccessCode: String?) -> Bool {
        guard actions.contains(where: { $0.1 == path }) else { return false }
        if path == notify {
            let host = headers["host"]?.lowercased().split(separator: ":").first.map(String.init)
            return isLocal && (host == "127.0.0.1" || host == "localhost")
                && headers["origin"] == nil && headers["forwarded"] == nil
                && headers["x-forwarded-for"] == nil && headers["x-forwarded-proto"] == nil
                && headers["cf-ray"] == nil && headers["cf-connecting-ip"] == nil
        }
        guard let masterAccessCode, !masterAccessCode.isEmpty,
              let authorization = headers["authorization"], authorization.hasPrefix("Bearer ") else { return false }
        return String(authorization.dropFirst("Bearer ".count)) == masterAccessCode
    }

    @MainActor
    static func register(on server: MCPServer) {
        server.registerHTTPRoute(method: "POST", path: registration) { _, _, _, body in
            await store.registerDevice(body)
        }
        server.registerHTTPRoute(method: "POST", path: notify) { _, _, _, body in
            await store.sendNotification(body)
        }
    }
}

private actor DeviceStore {
    private var base: URL {
        let override = ProcessInfo.processInfo.environment["NEO_APNS_HOME"]
        return override.map { URL(fileURLWithPath: $0, isDirectory: true) } ??
          FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NeoY/apns", isDirectory: true)
    }
    private var devicesURL: URL { base.appendingPathComponent("devices.json") }
    private var configURL: URL { base.appendingPathComponent("config.json") }

    private func response(_ status: Int, _ data: [String: Any]) -> HTTPRouteResponse {
        HTTPRouteResponse(status: status, body: try? JSONSerialization.data(withJSONObject: data),
                          contentType: "application/json")
    }
    private func decode(_ data: Data?) -> [String: Any]? {
        guard let data, data.count <= 524_288,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }
    private func load(_ url: URL, fallback: [String: Any]) -> [String: Any] {
        guard let bytes = try? Data(contentsOf: url),
              let dictionary = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return fallback }
        return dictionary
    }
    private func save(_ data: [String: Any], to file: URL) throws {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let bytes = try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys])
        try bytes.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func deviceRecords() -> [String: Any] {
        load(devicesURL, fallback: ["version": 1, "devices": [:]])
    }
    func registerDevice(_ body: Data?) -> HTTPRouteResponse {
        guard let input = decode(body),
              let id = input["deviceId"] as? String, UUID(uuidString: id) != nil else {
            return response(400, ["error": "invalid_device_registration"])
        }
        let token = input["token"] as? String
        let environment = input["environment"] as? String
        if (token != nil) != (environment != nil) {
            return response(400, ["error": "token_and_environment_required_together"])
        }
        if let token {
            guard (64...512).contains(token.count),
                  token.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 || $0 >= 97 && $0 <= 102 || $0 >= 65 && $0 <= 70 }),
                  let environment, ["production", "sandbox"].contains(environment) else {
                return response(400, ["error": "invalid_device_token"])
            }
        }
        var database = deviceRecords()
        var records = database["devices"] as? [String: Any] ?? [:]
        var current = records[id.lowercased()] as? [String: String] ?? [:]
        if let token, let environment {
            current["token"] = token.lowercased()
            current["environment"] = environment
        }
        current["updatedAt"] = ISO8601DateFormatter().string(from: Date())
        records[id.lowercased()] = current
        database["devices"] = records
        do { try save(database, to: devicesURL) }
        catch { return response(503, ["error": "device_store_unavailable"]) }
        return response(200, ["registered": true, "deviceId": id.lowercased(),
                              "environment": environment ?? "unassigned"])
    }

    func sendNotification(_ body: Data?) async -> HTTPRouteResponse {
        guard let input = decode(body),
              let id = input["id"] as? String, UUID(uuidString: id) != nil,
              let title = input["title"] as? String, !title.isEmpty, title.count <= 180,
              let message = input["body"] as? String, !message.isEmpty, message.count <= 180,
              let payload = input["payload"] as? [String: String], payload.count <= 8,
              payload.allSatisfy({ key, value in
                  key.range(of: "^[A-Za-z][A-Za-z0-9_]{0,63}$", options: .regularExpression) != nil &&
                  !["aps", "__proto__", "constructor"].contains(key) && value.count <= 256
              }) else { return response(400, ["error": "invalid_notification"]) }
        let config = load(configURL, fallback: [:])
        guard let keyId = config["keyId"] as? String, keyId.count == 10,
              let teamId = config["teamId"] as? String, teamId.count == 10,
              let keyPath = config["keyPath"] as? String,
              let topic = config["topic"] as? String, topic == "com.neox.app",
              let privateKey = try? String(contentsOfFile: keyPath, encoding: .utf8),
              let key = try? P256.Signing.PrivateKey(pemRepresentation: privateKey) else {
            return response(200, ["accepted": false, "reason": "apns_not_configured"])
        }
        let devices = deviceRecords()["devices"] as? [String: [String: String]] ?? [:]
        if devices.isEmpty { return response(200, ["accepted": false, "reason": "no_registered_devices"]) }
        let issueTime = Int(Date().timeIntervalSince1970)
        func base64URL(_ bytes: Data) -> String {
            bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
              .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let header = base64URL(Data("{\"alg\":\"ES256\",\"kid\":\"\(keyId)\"".utf8) + Data("}".utf8))
        let claims = base64URL(Data("{\"iss\":\"\(teamId)\",\"iat\":\(issueTime)}".utf8))
        let signingInput = header + "." + claims
        guard let signature = try? key.signature(for: Data(signingInput.utf8)) else {
            return response(200, ["accepted": false, "reason": "jwt_signing_failure"])
        }
        let authorization = "bearer " + signingInput + "." + base64URL(signature.rawRepresentation)
        var apns: [String: Any] = ["aps": ["alert": ["title": title, "body": message], "sound": "default"]]
        for (key, value) in payload { apns[key] = value }
        guard let bytes = try? JSONSerialization.data(withJSONObject: apns), bytes.count <= 4096 else {
            return response(400, ["error": "notification_too_large"])
        }
        var accepted = false
        for (deviceId, record) in devices.prefix(10) {
            guard let token = record["token"], let environment = record["environment"],
                  ["sandbox", "production"].contains(environment) else { continue }
            let hostname = environment == "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com"
            guard let url = URL(string: "https://\(hostname)/3/device/\(token)") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 12
            request.httpBody = bytes
            request.setValue(authorization, forHTTPHeaderField: "authorization")
            request.setValue(topic, forHTTPHeaderField: "apns-topic")
            request.setValue("alert", forHTTPHeaderField: "apns-push-type")
            request.setValue("10", forHTTPHeaderField: "apns-priority")
            request.setValue(id, forHTTPHeaderField: "apns-id")
            request.setValue(id, forHTTPHeaderField: "apns-collapse-id")
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            do {
                let (_, result) = try await URLSession.shared.data(for: request)
                if (result as? HTTPURLResponse)?.statusCode == 200 { accepted = true }
                // An APNs rejection is not a failed Preview request: the client
                // can still acquire it on its next connection.
            } catch {
                NSLog("NeoY APNs transport for device %@ unavailable", deviceId)
            }
        }
        return response(200, ["accepted": accepted, "status": "apns_submission"])
    }
}
