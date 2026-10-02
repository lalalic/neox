import Foundation

enum NeoYRuntimeControlError: LocalizedError {
    case federation(String)
    case event(String)

    var errorDescription: String? {
        switch self {
        case .federation(let value), .event(let value): value
        }
    }
}

@MainActor
final class NeoYRuntimeControl {
    private let federation: NeoYMCPFederation
    private let phone: NeoXPhoneClient

    init(server: MCPServer, phone: NeoXPhoneClient) {
        self.federation = NeoYMCPFederation(server: server)
        self.phone = phone
    }

    func reconcile(_ configuration: NeoYControlPlaneConfiguration) async {
        await federation.reconcile(configuration.mcpServers)
    }

    func permissions() async -> [NeoYPermissionStatus] {
        await NeoYPermissionService.snapshot()
    }

    func openPermission(_ kind: NeoYPermissionKind) -> Bool {
        NeoYPermissionService.open(kind)
    }


    func federationStatus(_ configuration: NeoYControlPlaneConfiguration) -> [NeoYFederatedServerStatus] {
        federation.statuses(configurations: configuration.mcpServers)
    }

    func iphoneNotify(kind: NeoYImportantEventKind, title: String, body: String, configuration: NeoYControlPlaneConfiguration) async throws -> String {
        guard configuration.events.isEnabled(kind) else {
            return "{\"delivered\":false,\"reason\":\"disabled_by_policy\"}"
        }
        return try await phone.callTool("event.iphone.notify", arguments: .object([
            "kind": .string(kind.rawValue), "title": .string(title), "body": .string(body),
        ]))
    }

    func stop() { federation.stop() }
}
