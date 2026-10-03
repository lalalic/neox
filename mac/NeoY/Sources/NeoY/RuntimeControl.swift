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
        let featureServers = await NeoYFeatureManager.shared.enabledMCPServers()
        let providers = Set(featureServers.map(\.name))
        let userServers = configuration.mcpServers.filter { !providers.contains($0.name) } + featureServers
        await federation.reconcile(NeoYBundledRuntime.resolvedMCPServers(userServers: userServers))
    }

    func permissions() async -> [NeoYPermissionStatus] {
        await NeoYPermissionService.snapshot()
    }

    func openPermission(_ kind: NeoYPermissionKind) -> Bool {
        NeoYPermissionService.open(kind)
    }


    func federationStatus(_ configuration: NeoYControlPlaneConfiguration) async -> [NeoYFederatedServerStatus] {
        let featureServers = await NeoYFeatureManager.shared.enabledMCPServers()
        let providers = Set(featureServers.map(\.name))
        let userServers = configuration.mcpServers.filter { !providers.contains($0.name) } + featureServers
        return federation.statuses(configurations: NeoYBundledRuntime.resolvedMCPServers(userServers: userServers))
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
