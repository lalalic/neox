import Foundation

enum NeoXPhoneTools {
    static func tools(client: NeoXPhoneClient, handoff: NativeNeoYPhoneHandoffReceiver) -> [ToolDefinition] {
        let commands: [ToolDefinition] = [
            ToolDefinition(
                name: "phone.status",
                description: "Check the selected NeoX phone MCP endpoint and the native _neoy._tcp handoff receiver.",
                parameters: schema([:])
            ) { _ in
                let phone: Any
                do { phone = try JSONSerialization.jsonObject(with: Data(try await client.status().utf8)) }
                catch { phone = ["selected": false, "error": error.localizedDescription] }
                let handoffText = await MainActor.run { handoff.statusJSON() }
                return NeoXPhoneClient.jsonString([
                    "phone": phone,
                    "handoff": try JSONSerialization.jsonObject(with: Data(handoffText.utf8)),
                ])
            },
            ToolDefinition(
                name: "phone.media.search",
                description: "Search the connected NeoX phone using the authoritative media.search API.",
                parameters: schema([
                    "media_type": stringProp("all, image, or video"),
                    "days": intProp("Only assets from the last N days"),
                    "album": stringProp("Exact album name"),
                    "favorited": boolProp("Only favorited assets"),
                    "has_label": stringProp("Vision-index label keyword"),
                    "has_text": stringProp("Vision-index OCR keyword"),
                    "with_people": boolProp("Only assets with people"),
                    "limit": intProp("Maximum assets (default 50)"),
                    "offset": intProp("Pagination offset"),
                ])
            ) { arguments in
                try await client.search(arguments: arguments)
            },
            ToolDefinition(
                name: "phone.media.meta",
                description: "Get full NeoX metadata for one asset id.",
                parameters: schema(["id": stringProp("NeoX asset id")], required: ["id"])
            ) { arguments in
                try await client.metadata(arguments: arguments)
            },
            ToolDefinition(
                name: "phone.media.thumbnail",
                description: "Get NeoX's generated thumbnail URL and dimensions for practical media selection.",
                parameters: schema([
                    "id": stringProp("NeoX asset id"),
                    "max_side": intProp("Maximum pixel edge (default 1024)"),
                ], required: ["id"])
            ) { arguments in
                try await client.thumbnail(arguments: arguments)
            },
            ToolDefinition(
                name: "phone.media.export",
                description: """
                Export one or more NeoX assets and stream each returned /files URL to a deterministic \
                local path under NeoY exports. Returns local_path, local_file_url, and local_reference.
                """,
                parameters: schema([
                    "ids": arrayProp("NeoX asset ids from phone.media.search"),
                    "preset": stringProp("original, 720p, or 1080p"),
                ], required: ["ids"])
            ) { arguments in
                try await client.exportAndDownload(arguments: arguments)
            },
        ]
        return [CommandTool.facade(
            name: "phone",
            description: "Inspect the paired NeoX phone and work with its media library.",
            commands: commands,
            commandName: { value in
                if value == "phone.status" { return "status" }
                if value.hasPrefix("phone.media.") { return "media." + String(value.dropFirst("phone.media.".count)) }
                return value
            }
        )]
    }

    private static func stringProp(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func intProp(_ description: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(description)])
    }

    private static func boolProp(_ description: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    private static func arrayProp(_ description: String) -> JSONValue {
        .object([
            "type": .string("array"),
            "description": .string(description),
            "items": .object(["type": .string("string")]),
        ])
    }

    private static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var value: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            value["required"] = .array(required.map(JSONValue.string))
        }
        return .object(value)
    }
}
