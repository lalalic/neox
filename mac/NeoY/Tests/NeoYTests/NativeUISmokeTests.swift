import Foundation
import XCTest

@testable import NeoY

final class NativeUISmokeTests: XCTestCase {
    @MainActor
    func testNativeSmokeDescriptorResourceAndResultShareOneURI() async throws {
        let server = MCPServer(name: "test", port: 0)
        NativeUISmoke.register(on: server)
        XCTAssertEqual(NativeUISmoke.resourceURI, "ui://widget/neoy-smoke-v3.html")

        let descriptorData = Data(server.toolDescriptorsJSON.utf8)
        let descriptors = try XCTUnwrap(try JSONSerialization.jsonObject(with: descriptorData) as? [[String: Any]])
        let tool = try XCTUnwrap(descriptors.first { $0["name"] as? String == NativeUISmoke.toolName })
        let meta = try XCTUnwrap(tool["_meta"] as? [String: Any])
        let ui = try XCTUnwrap(meta["ui"] as? [String: Any])
        XCTAssertEqual(ui["resourceUri"] as? String, NativeUISmoke.resourceURI)
        XCTAssertEqual(meta["ui/resourceUri"] as? String, NativeUISmoke.resourceURI)
        XCTAssertEqual(meta["openai/outputTemplate"] as? String, NativeUISmoke.resourceURI)
        XCTAssertEqual(Set(server.resourceURIs), Set([NativeUISmoke.resourceURI, NativeUISmoke.legacyResourceURI]))

        let result = try await server.invokeRegisteredTool(NativeUISmoke.toolName, arguments: .object([:]))
        let resultObject = try decodeResult(result)
        let structured = try XCTUnwrap(resultObject["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["resourceUri"] as? String, NativeUISmoke.resourceURI)
        let resultMeta = try XCTUnwrap(resultObject["_meta"] as? [String: Any])
        XCTAssertEqual((resultMeta["ui"] as? [String: Any])?["resourceUri"] as? String, NativeUISmoke.resourceURI)
    }

    func testServerAdvertisesMCPAppsExtension() throws {
        guard case .object(let capabilities) = MCPServer.advertisedCapabilities,
              case .object(let extensions)? = capabilities["extensions"],
              case .object(let ui)? = extensions[MCPServer.mcpAppExtensionID],
              case .array(let mimeTypes)? = ui["mimeTypes"] else {
            return XCTFail("MCP Apps extension capability missing")
        }
        XCTAssertEqual(mimeTypes, [.string(NativeUISmoke.mimeType)])
    }

    func testNativeSmokeHTMLPerformsMCPAppsViewHandshake() {
        XCTAssertTrue(NativeUISmoke.html.contains("ui/initialize"))
        XCTAssertTrue(NativeUISmoke.html.contains("ui/notifications/initialized"))
        XCTAssertTrue(NativeUISmoke.html.contains("appInfo"))
        XCTAssertTrue(NativeUISmoke.html.contains("appCapabilities"))
    }

    func testNativeSmokeResourcesReturnPrivateNoCacheHints() throws {
        for uri in [NativeUISmoke.resourceURI, NativeUISmoke.legacyResourceURI] {
            let result = try NativeUISmoke.resourceResult(uri: uri)
            let object = try decodeResult(result)
            XCTAssertEqual(object["ttlMs"] as? Int, 0)
            XCTAssertEqual(object["cacheScope"] as? String, "private")
        }
    }

    func testNativeSmokeResourceCanBeExplicitlyAllowedRemotelyWithoutOpeningWidgetProvider() {
        XCTAssertTrue(MCPServer.remoteResourceAllowed(
            uri: NativeUISmoke.resourceURI,
            explicitURIs: [NativeUISmoke.resourceURI, NativeUISmoke.legacyResourceURI],
            providers: []
        ))
        XCTAssertTrue(MCPServer.remoteResourceAllowed(
            uri: NativeUISmoke.legacyResourceURI,
            explicitURIs: [NativeUISmoke.resourceURI, NativeUISmoke.legacyResourceURI],
            providers: []
        ))
        XCTAssertFalse(MCPServer.remoteResourceAllowed(
            uri: "ui://widget/other.html",
            explicitURIs: [NativeUISmoke.resourceURI, NativeUISmoke.legacyResourceURI],
            providers: []
        ))
    }

    private func decodeResult(_ encoded: String) throws -> [String: Any] {
        let prefix = "mcpresult:"
        XCTAssertTrue(encoded.hasPrefix(prefix))
        let data = try XCTUnwrap(Data(base64Encoded: String(encoded.dropFirst(prefix.count))))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
