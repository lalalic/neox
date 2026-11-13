import XCTest
@testable import NeoxApp

@MainActor
final class MarkcutAppOnlyRoutingTests: XCTestCase {
    func testAppOnlyReviewAndMediaDoNotRequireModelVisibleToolListing() {
        XCTAssertEqual(RemoteMCPClient.resolvedToolName("review.preview.acquire", advertised: []), "review.preview.acquire")
        XCTAssertEqual(RemoteMCPClient.resolvedToolName("markcut.preview.media", advertised: []), "markcut.preview.media")
        XCTAssertEqual(RemoteMCPClient.resolvedToolName("markcut.preview.media", advertised: ["mcp.markcut"]), "markcut.preview.media")
    }

    func testRegularToolsStillRequireDiscovery() {
        XCTAssertNil(RemoteMCPClient.resolvedToolName("events", advertised: []))
        XCTAssertEqual(RemoteMCPClient.resolvedToolName("chatgpt", advertised: ["mcp.chatgpt"]), "mcp.chatgpt")
        XCTAssertNil(RemoteMCPClient.resolvedToolName("another.private.tool", advertised: []))
    }
}
