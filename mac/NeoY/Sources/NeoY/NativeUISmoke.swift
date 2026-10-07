import Foundation

/// Temporary native MCP App probe used to isolate ChatGPT widget ingestion
/// from NeoY's federation layer. Remove after the host-side issue is resolved.
enum NativeUISmoke {
    static let toolName = "neoy.ui_smoke"
    static let resourceURI = "ui://widget/neoy-smoke-v3.html"
    static let legacyResourceURI = "ui://widget/neoy-smoke-v2.html"
    static let mimeType = MCPServer.mcpAppMimeType

    @MainActor
    static func register(on server: MCPServer) {
        server.setRemoteAllowedResourceURIs([resourceURI, legacyResourceURI])
        let resourceMeta: JSONValue = .object([
            "ui": .object([
                "prefersBorder": .bool(true),
                "csp": .object([
                    "connectDomains": .array([]),
                    "resourceDomains": .array([]),
                ]),
            ]),
        ])
        let descriptor: JSONValue = .object([
            "name": .string(toolName),
            "description": .string("Render a minimal native NeoY MCP App smoke-test widget."),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false),
            ]),
            "_meta": .object([
                "ui": .object(["resourceUri": .string(resourceURI)]),
                "ui/resourceUri": .string(resourceURI),
                "openai/outputTemplate": .string(resourceURI),
            ]),
        ])
        server.registerFederatedTool(descriptor: descriptor, name: toolName, protected: true) { _ in
            try encodeResult([
                "content": [["type": "text", "text": "NeoY native UI smoke test"]],
                "structuredContent": ["resourceUri": resourceURI, "status": "ok"],
                "_meta": [
                    "ui": ["resourceUri": resourceURI],
                    "ui/resourceUri": resourceURI,
                    "openai/outputTemplate": resourceURI,
                ],
            ])
        }
        registerResource(on: server, uri: resourceURI, name: "NeoY Native UI Smoke", resourceMeta: resourceMeta)
        registerResource(on: server, uri: legacyResourceURI, name: "NeoY Native UI Smoke (compatibility alias)", resourceMeta: resourceMeta)
    }

    @MainActor
    private static func registerResource(on server: MCPServer, uri: String, name: String, resourceMeta: JSONValue) {
        server.registerFederatedResource(
            descriptor: .object([
                "uri": .string(uri),
                "name": .string(name),
                "mimeType": .string(mimeType),
                "_meta": resourceMeta,
            ]),
            uri: uri
        ) { _ in
            try encodeResult([
                "contents": [[
                    "uri": uri,
                    "mimeType": mimeType,
                    "text": html,
                    "_meta": [
                        "ui": [
                            "prefersBorder": true,
                            "csp": [
                                "connectDomains": [],
                                "resourceDomains": [],
                            ],
                        ],
                    ],
                ]],
            ])
        }
    }

    static let html = """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <style>body{font-family:system-ui,sans-serif;margin:0;padding:24px;background:#fff;color:#111}main{border:1px solid #ddd;border-radius:16px;padding:24px}h1{font-size:24px;margin:0 0 8px}p{margin:0;color:#555}</style></head>
    <body><main><h1>NeoY UI Smoke</h1><p id="status">Native MCP App resource loaded. Connecting to host…</p></main>
    <script>
      let nextId = 1;
      const pending = new Map();
      const status = document.getElementById("status");

      function sendRequest(method, params) {
        const id = nextId++;
        window.parent.postMessage({ jsonrpc: "2.0", id, method, params }, "*");
        return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
      }

      function sendNotification(method, params = {}) {
        window.parent.postMessage({ jsonrpc: "2.0", method, params }, "*");
      }

      window.addEventListener("message", (event) => {
        if (event.source !== window.parent) return;
        const message = event.data;
        if (!message || typeof message !== "object") return;

        if (message.id !== undefined && pending.has(message.id)) {
          const request = pending.get(message.id);
          pending.delete(message.id);
          if (Object.prototype.hasOwnProperty.call(message, "result")) request.resolve(message.result);
          else request.reject(new Error(message.error?.message || "MCP App host rejected initialization"));
          return;
        }

        if (message.method === "ui/notifications/tool-result") {
          const result = message.params?.result ?? message.params;
          if (result?.structuredContent?.status === "ok" || result?.structured_content?.status === "ok") {
            status.textContent = "Native MCP App resource loaded successfully.";
          }
        }
      });

      (async () => {
        try {
          await sendRequest("ui/initialize", {
            protocolVersion: "2026-01-26",
            appInfo: { name: "NeoY UI Smoke", version: "1.0.0" },
            appCapabilities: {}
          });
          sendNotification("ui/notifications/initialized");
          status.textContent = "Native MCP App host connected successfully.";
        } catch (error) {
          status.textContent = "Native MCP App resource loaded; host handshake unavailable.";
        }
      })();
    </script></body></html>
    """

    private static func encodeResult(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return "mcpresult:" + data.base64EncodedString()
    }
}
