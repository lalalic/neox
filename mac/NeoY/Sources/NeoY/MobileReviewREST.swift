import Foundation

/// Private phone-facing HTTP surface of Neo.app Core.
/// Notification is reachable only from a direct local connection; mobile
/// register/pending/complete require the existing Master Access Code.
/// No review commands are published in MCP tools/list.
enum NeoYMobileReviewREST {
    static let prefix = "/mobile/review/"
    static let actions: [(String, String, String)] = [
        ("POST", "/mobile/review/register", "register"),
        ("GET", "/mobile/review/pending", "pending"),
        ("POST", "/mobile/review/complete", "complete"),
        ("POST", "/mobile/review/notify", "notify"),
    ]

    nonisolated static func allowed(path: String, isLocal: Bool,
                                    headers: [String: String], masterAccessCode: String?) -> Bool {
        guard actions.contains(where: { $0.1 == path }) else { return false }
        if path == "/mobile/review/notify" {
            // Do not trust reverse proxies just because their socket is local.
            let host = headers["host"]?.lowercased().split(separator: ":").first.map(String.init)
            return isLocal && (host == "127.0.0.1" || host == "localhost")
                && headers["origin"] == nil && headers["forwarded"] == nil
                && headers["x-forwarded-for"] == nil && headers["x-forwarded-proto"] == nil
                && headers["cf-ray"] == nil && headers["cf-connecting-ip"] == nil
        }
        guard let masterAccessCode, !masterAccessCode.isEmpty,
              let raw = headers["authorization"], raw.hasPrefix("Bearer ") else { return false }
        return String(raw.dropFirst("Bearer ".count)) == masterAccessCode
    }

    @MainActor
    static func register(on server: MCPServer, moduleURL: URL? = nil) {
        for (method, path, action) in actions {
            server.registerHTTPRoute(method: method, path: path) { _, _, _, body in
                await perform(action: action, body: body, moduleURL: moduleURL)
            }
        }
    }

    nonisolated private static func failure(_ status: Int, _ code: String) -> HTTPRouteResponse {
        let data = try? JSONSerialization.data(withJSONObject: ["error": code])
        return HTTPRouteResponse(status: status, body: data, contentType: "application/json")
    }

    nonisolated private static func perform(action: String, body: Data?, moduleURL: URL?) async -> HTTPRouteResponse {
        if action != "pending" {
            guard let body, !body.isEmpty, body.count <= 524_288,
                  (try? JSONSerialization.jsonObject(with: body)) is [String: Any] else {
                return failure(400, "invalid_json_body")
            }
        }
        let module = moduleURL ?? NeoYManagedCoreRuntime.selected()
            .appendingPathComponent("src/core/tools/review.mjs")
        guard FileManager.default.isReadableFile(atPath: module.path),
              let node = NeoYManagedCoreRuntime.nodeExecutable else {
            return failure(503, "review_core_unavailable")
        }
        return await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = node
            process.arguments = [module.path, action]
            let input = Pipe(), output = Pipe(), error = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = error
            do {
                try process.run()
                input.fileHandleForWriting.write(body ?? Data())
                try? input.fileHandleForWriting.close()
                let response = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return failure(422, "review_operation_rejected") }
                guard response.count <= 8_000_000,
                      let json = try? JSONSerialization.jsonObject(with: response),
                      json is [String: Any] else { return failure(502, "invalid_core_receipt") }
                return HTTPRouteResponse(status: 200, body: response, contentType: "application/json")
            } catch { return failure(503, "review_core_unavailable") }
        }.value
    }
}
