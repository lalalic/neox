import Foundation

/// HTTP-only view of the existing Neo CLI bootstrap. No new MCP tool is registered.
/// The CLI owns rule and Skill discovery; NeoY owns the authenticated gateway.
enum NeoYXChatBootstrapRoute {
    @MainActor
    static func register(on server: MCPServer) {
        server.registerHTTPRoute(method: "GET", path: "/xchat/bootstrap") { _, _, _, _ in
            await Task.detached(priority: .utility) { render() }.value
        }
    }

    static func render(cli: URL? = NeoCLISetup.cliPath()) -> HTTPRouteResponse {
        guard let cli else {
            return HTTPRouteResponse(status: 503, body: Data("Neo CLI unavailable".utf8),
                                     contentType: "text/plain; charset=utf-8")
        }
        let process = Process()
        process.executableURL = cli
        process.arguments = ["bootstrap"]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        ]) { _, preferred in preferred }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, !data.isEmpty,
                  let markdown = String(data: data, encoding: .utf8),
                  markdown.hasPrefix("# XChat Harness Bootstrap") else {
                return HTTPRouteResponse(status: 503, body: Data("Bootstrap unavailable".utf8),
                                         contentType: "text/plain; charset=utf-8")
            }
            return HTTPRouteResponse(status: 200, body: data,
                                     contentType: "text/markdown; charset=utf-8")
        } catch {
            return HTTPRouteResponse(status: 503, body: Data("Bootstrap unavailable".utf8),
                                     contentType: "text/plain; charset=utf-8")
        }
    }
}
