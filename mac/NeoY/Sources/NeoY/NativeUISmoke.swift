import Foundation

/// Temporary native MCP App probe used to isolate ChatGPT widget ingestion
/// from NeoY's federation layer. Remove after the host-side issue is resolved.
enum NativeUISmoke {
    static let toolName = "neoy.ui_smoke"
    static let resourceURI = "ui://widget/neoy-smoke-v2.html"
    static let mimeType = "text/html;profile=mcp-app"

    @MainActor
    static func register(on server: MCPServer) {
        server.setRemoteAllowedResourceURIs([resourceURI])
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
        server.registerFederatedResource(
            descriptor: .object([
                "uri": .string(resourceURI),
                "name": .string("NeoY Native UI Smoke"),
                "mimeType": .string(mimeType),
                "_meta": resourceMeta,
            ]),
            uri: resourceURI
        ) { _ in
            try encodeResult([
                "contents": [[
                    "uri": resourceURI,
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

    private static let html = """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <style>body{font-family:system-ui,sans-serif;margin:0;padding:24px;background:#fff;color:#111}main{border:1px solid #ddd;border-radius:16px;padding:24px}h1{font-size:24px;margin:0 0 8px}p{margin:0;color:#555}</style></head>
    <body><main><h1>NeoY UI Smoke</h1><p>Native MCP App resource loaded successfully.</p></main></body></html>
    """

    private static func encodeResult(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return "mcpresult:" + data.base64EncodedString()
    }
}
