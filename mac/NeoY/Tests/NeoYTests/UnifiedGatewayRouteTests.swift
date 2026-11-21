import Foundation
import XCTest
@testable import NeoY

final class UnifiedGatewayRouteTests: XCTestCase {
    func testUnauthenticatedAndMethodEscalationFailClosed() {
        XCTAssertNil(UnifiedGatewayRoute.match(method: "GET", path: "/dashboard/", browserAuthorized: false, bearerAuthorized: false))
        XCTAssertNil(UnifiedGatewayRoute.match(method: "GET", path: "/orchestrator-chat/pending", browserAuthorized: true, bearerAuthorized: false))
        XCTAssertNil(UnifiedGatewayRoute.match(method: "POST", path: "/orchestrator-chat/pending", browserAuthorized: false, bearerAuthorized: true))
        XCTAssertNil(UnifiedGatewayRoute.match(method: "POST", path: "/relay/api/mobile/job-cancel", browserAuthorized: true, bearerAuthorized: false))
        XCTAssertNil(UnifiedGatewayRoute.match(method: "GET", path: "/relay/api/mobile/jobs", browserAuthorized: true, bearerAuthorized: false))
        XCTAssertNil(UnifiedGatewayRoute.match(method: "PUT", path: "/relay/api/jobs", browserAuthorized: true, bearerAuthorized: true))
    }

    func testUnauthenticatedDashboardNavigationRedirectsOnlyHtmlEntryPages() {
        for path in ["/dashboard/", "/dashboard/index.html"] {
            XCTAssertTrue(UnifiedGatewayRoute.needsDashboardLogin(method: "GET", path: path,
                browserAuthorized: false, bearerAuthorized: false))
            XCTAssertFalse(UnifiedGatewayRoute.needsDashboardLogin(method: "GET", path: path,
                browserAuthorized: true, bearerAuthorized: false))
            XCTAssertFalse(UnifiedGatewayRoute.needsDashboardLogin(method: "GET", path: path,
                browserAuthorized: false, bearerAuthorized: true))
        }
        for path in ["/dashboard/dashboard.js", "/dashboard/manifest.webmanifest", "/dashboard/../secret",
                     "/relay/api/jobs", "/dashboard/csrf", "/dashboard/login"] {
            XCTAssertFalse(UnifiedGatewayRoute.needsDashboardLogin(method: "GET", path: path,
                browserAuthorized: false, bearerAuthorized: false), path)
        }
        XCTAssertFalse(UnifiedGatewayRoute.needsDashboardLogin(method: "POST", path: "/dashboard/",
            browserAuthorized: false, bearerAuthorized: false))
    }

    func testRouteAllowlistAndPrivateLoopbackPorts() {
        let model = UnifiedGatewayRoute.match(method: "POST", path: "/orchestrator-chat/messages", browserAuthorized: false, bearerAuthorized: true)
        XCTAssertEqual(model?.port, 8769)
        XCTAssertEqual(model?.path, "/orchestrator-chat/messages")
        XCTAssertTrue(model?.requiresModelToken == true)
        XCTAssertFalse(model?.streaming == true)
        let stream = UnifiedGatewayRoute.match(method: "GET", path: "/orchestrator-chat/events", browserAuthorized: false, bearerAuthorized: true)
        XCTAssertTrue(stream?.streaming == true)
        let health = UnifiedGatewayRoute.match(method: "GET", path: "/orchestrator-chat/health",
                                               browserAuthorized: false, bearerAuthorized: true)
        XCTAssertEqual(health?.port, 8769)
        XCTAssertNil(UnifiedGatewayRoute.match(method: "GET", path: "/orchestrator-chat/health",
                                                browserAuthorized: true, bearerAuthorized: false))
        let dashboard = UnifiedGatewayRoute.match(method: "GET", path: "/dashboard/", browserAuthorized: true, bearerAuthorized: false)
        XCTAssertEqual(dashboard?.path, "/")
        XCTAssertEqual(dashboard?.port, 8787)
        let relay = UnifiedGatewayRoute.match(method: "POST", path: "/relay/api/mobile/job-cancel", browserAuthorized: false, bearerAuthorized: true)
        XCTAssertEqual(relay?.path, "/api/mobile/job-cancel")
        XCTAssertFalse(relay?.requiresModelToken == true)
    }

    func testTraversalAndUnknownRoutesFailClosed() {
        for path in ["/dashboard/../admin", "/dashboard/%2e%2e/admin", "/dashboard//index.html", "/dashboard/.env", "/relay/api/../private", "/orchestrator-chat/admin", "/orchestrator-chat/messages/extra"] {
            XCTAssertNil(UnifiedGatewayRoute.match(method: "GET", path: path, browserAuthorized: true, bearerAuthorized: true), path)
        }
    }

    func testCookieSessionIsSeparateFromBearerAuthentication() {
        let store = UnifiedGatewayBrowserSessions()
        let (cookie, csrf) = store.login()
        XCTAssertTrue(cookie.contains("Secure; HttpOnly; SameSite=Strict"))
        let token = cookie.components(separatedBy: ";")[0]
        XCTAssertEqual(store.csrf(cookieHeader: token), csrf)
        XCTAssertNil(store.csrf(cookieHeader: "neo_gateway_session=wrong"))
        XCTAssertNil(store.csrf(cookieHeader: ""))
    }
}
