import Foundation

@MainActor
final class NeoYRuntimeControl {
    private let supervisor: NeoYStartupSupervisor
    private let federation: NeoYMCPFederation
    private let phone: NeoXPhoneClient

    init(
        server: MCPServer,
        phone: NeoXPhoneClient,
        supervisor: NeoYStartupSupervisor = NeoYStartupSupervisor()
    ) {
        self.supervisor = supervisor
        self.federation = NeoYMCPFederation(server: server)
        self.phone = phone
    }

    func reconcile(_ configuration: NeoYControlPlaneConfiguration) async {
        supervisor.reconcile(configuration.startupServices)
        await federation.reconcile(configuration.mcpServers)
    }

    func permissions() async -> [NeoYPermissionStatus] {
        await NeoYPermissionService.snapshot()
    }

    func openPermission(_ kind: NeoYPermissionKind) -> Bool {
        NeoYPermissionService.open(kind)
    }

    func startupStatus(_ configuration: NeoYControlPlaneConfiguration) -> [NeoYStartupServiceStatus] {
        supervisor.statuses(configurations: configuration.startupServices)
    }

    func federationStatus(_ configuration: NeoYControlPlaneConfiguration) -> [NeoYFederatedServerStatus] {
        federation.statuses(configurations: configuration.mcpServers)
    }

    func notify(
        kind: NeoYImportantEventKind,
        title: String,
        body: String,
        configuration: NeoYControlPlaneConfiguration
    ) async throws -> String {
        guard configuration.events.isEnabled(kind) else {
            return "{\"delivered\":false,\"reason\":\"disabled_by_policy\"}"
        }
        return try await phone.callTool("event.notify", arguments: .object([
            "kind": .string(kind.rawValue),
            "title": .string(title),
            "body": .string(body),
        ]))
    }

    func stop() {
        supervisor.stopAll()
        federation.stop()
    }
}
