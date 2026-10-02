import Foundation

enum NeoYControlPlaneSchema {
    static let currentVersion = 3
}

enum NeoYDiagnosticsLevel: String, Codable, CaseIterable, Sendable {
    case info, warning, error
}

enum NeoYDiagnosticsSetting: Equatable, Sendable {
    case level(NeoYDiagnosticsLevel)
    case retentionDays(Int)
}

struct NeoYDiagnosticsConfiguration: Codable, Equatable, Sendable {
    var isEnabled = false
    var level: NeoYDiagnosticsLevel = .info
    var retentionDays = 7

    func validate() throws {
        guard (1...365).contains(retentionDays) else {
            throw NeoYControlPlaneError.invalidRetentionDays(retentionDays)
        }
    }
}

enum NeoYRestartPolicy: String, Codable, CaseIterable, Sendable {
    case never
    case onFailure = "on-failure"
    case always
}

struct NeoYStartupServiceConfiguration: Codable, Equatable, Sendable {
    var name: String
    var executable: String
    var arguments: [String] = []
    var workingDirectory: String?
    var environment: [String: String] = [:]
    var isEnabled = true
    var restartPolicy: NeoYRestartPolicy = .onFailure

    func validate() throws {
        try NeoYControlPlaneValidation.name(name)
        guard executable.hasPrefix("/") else {
            throw NeoYControlPlaneError.invalidExecutable(executable)
        }
        if let workingDirectory, !workingDirectory.hasPrefix("/") {
            throw NeoYControlPlaneError.invalidWorkingDirectory(workingDirectory)
        }
        for key in environment.keys where key.isEmpty || key.contains("=") {
            throw NeoYControlPlaneError.invalidEnvironmentKey(key)
        }
    }
}

struct NeoYMCPServerConfiguration: Codable, Equatable, Sendable {
    var name: String
    var url: String
    var isEnabled = true

    func validate() throws {
        try NeoYControlPlaneValidation.name(name)
        guard let parsed = URL(string: url),
              let scheme = parsed.scheme?.lowercased() else {
            throw NeoYControlPlaneError.invalidMCPURL(url)
        }
        if ["http", "https"].contains(scheme) {
            guard parsed.host != nil else { throw NeoYControlPlaneError.invalidMCPURL(url) }
            return
        }
        if scheme == "stdio" {
            guard parsed.path.hasPrefix("/"), !parsed.path.isEmpty else {
                throw NeoYControlPlaneError.invalidMCPURL(url)
            }
            return
        }
        throw NeoYControlPlaneError.invalidMCPURL(url)
    }
}

enum NeoYImportantEventKind: String, Codable, CaseIterable, Sendable {
    case blocked, failure, completed
}

struct NeoYEventConfiguration: Codable, Equatable, Sendable {
    var blocked = true
    var failure = true
    var completed = true

    func isEnabled(_ kind: NeoYImportantEventKind) -> Bool {
        switch kind {
        case .blocked: blocked
        case .failure: failure
        case .completed: completed
        }
    }

    mutating func set(_ kind: NeoYImportantEventKind, enabled: Bool) {
        switch kind {
        case .blocked: blocked = enabled
        case .failure: failure = enabled
        case .completed: completed = enabled
        }
    }
}

enum NeoYOptionalCapability: String, Codable, CaseIterable, Sendable {
    case accessibilityComputer = "accessibility-computer"
    case demoRecording = "demo-recording"
    case captureTour = "capture-tour"
    case phoneIntegration = "phone-integration"
    case publicTunnel = "public-tunnel"
}

struct NeoYCapabilityConfiguration: Codable, Equatable, Sendable {
    var disabled: Set<NeoYOptionalCapability> = []

    func isEnabled(_ capability: NeoYOptionalCapability) -> Bool {
        !disabled.contains(capability)
    }

    mutating func set(_ capability: NeoYOptionalCapability, enabled: Bool) {
        if enabled { disabled.remove(capability) }
        else { disabled.insert(capability) }
    }
}

struct NeoYControlPlaneConfiguration: Codable, Equatable, Sendable {
    var diagnostics = NeoYDiagnosticsConfiguration()
    var startupServices: [NeoYStartupServiceConfiguration] = []
    var mcpServers: [NeoYMCPServerConfiguration] = []
    var events = NeoYEventConfiguration()
    var capabilities = NeoYCapabilityConfiguration()

    func validate() throws {
        try diagnostics.validate()
        try NeoYControlPlaneValidation.unique(startupServices.map(\.name), kind: "startup service")
        try NeoYControlPlaneValidation.unique(mcpServers.map(\.name), kind: "MCP server")
        try startupServices.forEach { try $0.validate() }
        try mcpServers.forEach { try $0.validate() }
    }
}

private enum NeoYControlPlaneValidation {
    static func name(_ value: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard !value.isEmpty, value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw NeoYControlPlaneError.invalidName(value)
        }
    }

    static func unique(_ values: [String], kind: String) throws {
        var seen = Set<String>()
        for value in values where !seen.insert(value).inserted {
            throw NeoYControlPlaneError.duplicateName(kind: kind, name: value)
        }
    }
}

struct NeoYControlPlaneDocument: Codable, Equatable, Sendable {
    var schemaVersion = NeoYControlPlaneSchema.currentVersion
    var configuration = NeoYControlPlaneConfiguration()

    func validate() throws {
        guard schemaVersion == NeoYControlPlaneSchema.currentVersion else {
            throw NeoYControlPlaneError.unsupportedSchemaVersion(
                found: schemaVersion, expected: NeoYControlPlaneSchema.currentVersion)
        }
        try configuration.validate()
    }
}

enum NeoYControlPlaneState: String, Codable, Sendable {
    case ready, degraded
}

struct NeoYControlPlaneHealth: Codable, Equatable, Sendable {
    var state = NeoYControlPlaneState.ready
    var schemaVersion = NeoYControlPlaneSchema.currentVersion
    var errorCode: String?
    var message: String?
    var recovery: String?
}

enum NeoYControlPlaneError: LocalizedError {
    case unreadableState(String)
    case malformedState(String)
    case unsupportedSchemaVersion(found: Int, expected: Int)
    case invalidRetentionDays(Int)
    case invalidDiagnosticsLevel(String)
    case invalidDiagnosticsProperty(String)
    case invalidName(String)
    case duplicateName(kind: String, name: String)
    case invalidExecutable(String)
    case invalidWorkingDirectory(String)
    case invalidEnvironmentKey(String)
    case invalidMCPURL(String)
    case missingItem(kind: String, name: String)
    case saveFailed(String)
    case unsupportedWhileDegraded(String)

    var errorDescription: String? {
        switch self {
        case .unreadableState(let reason): "configuration state could not be read: \(reason)"
        case .malformedState(let reason): "configuration state was malformed: \(reason)"
        case .unsupportedSchemaVersion(let found, let expected):
            "unsupported configuration schema version \(found); expected \(expected)"
        case .invalidRetentionDays(let value):
            "retention-days must be an integer from 1 through 365; got \(value)"
        case .invalidDiagnosticsLevel(let value):
            "level must be one of \(NeoYDiagnosticsLevel.allCases.map(\.rawValue).joined(separator: ", ")); got '\(value)'"
        case .invalidDiagnosticsProperty(let value):
            "unknown diagnostics property '\(value)'; supported properties: level, retention-days"
        case .invalidName(let value): "invalid name '\(value)'; use letters, digits, '.', '_' or '-'"
        case .duplicateName(let kind, let name): "duplicate \(kind) name '\(name)'"
        case .invalidExecutable(let value): "executable must be an absolute path; got '\(value)'"
        case .invalidWorkingDirectory(let value): "working directory must be an absolute path; got '\(value)'"
        case .invalidEnvironmentKey(let value): "invalid environment key '\(value)'"
        case .invalidMCPURL(let value): "MCP URL must be http(s) or stdio with an absolute executable path; got '\(value)'"
        case .missingItem(let kind, let name): "\(kind) '\(name)' does not exist"
        case .saveFailed(let reason): "configuration state could not be saved: \(reason)"
        case .unsupportedWhileDegraded(let reason): reason
        }
    }
}

struct NeoYControlPlaneLoadOutcome: Equatable, Sendable {
    var document = NeoYControlPlaneDocument()
    var health = NeoYControlPlaneHealth()
}

protocol NeoYControlPlaneStoring: Sendable {
    func loadOrCreate() throws -> NeoYControlPlaneLoadOutcome
    func save(_ document: NeoYControlPlaneDocument) throws
}

struct NeoYFileControlPlaneStore: NeoYControlPlaneStoring {
    private let directory: URL
    private let fileURL: URL
    private let date: @Sendable () -> Date

    init(directory: URL, date: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("control-plane.json")
        self.date = date
    }

    func loadOrCreate() throws -> NeoYControlPlaneLoadOutcome {
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { throw NeoYControlPlaneError.unreadableState(error.localizedDescription) }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let document = NeoYControlPlaneDocument()
            try save(document)
            return NeoYControlPlaneLoadOutcome(document: document)
        }

        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch { throw NeoYControlPlaneError.unreadableState(error.localizedDescription) }

        do {
            let decoder = JSONDecoder()
            let envelope = try decoder.decode(SchemaEnvelope.self, from: data)
            if envelope.schemaVersion == 1 {
                let legacy = try decoder.decode(V1Document.self, from: data)
                let migrated = NeoYControlPlaneDocument(
                    configuration: NeoYControlPlaneConfiguration(diagnostics: legacy.configuration.diagnostics))
                try save(migrated)
                return NeoYControlPlaneLoadOutcome(document: migrated)
            }
            if envelope.schemaVersion == 2 {
                let legacy = try decoder.decode(V2Document.self, from: data)
                let migrated = NeoYControlPlaneDocument(
                    configuration: NeoYControlPlaneConfiguration(
                        diagnostics: legacy.configuration.diagnostics,
                        startupServices: legacy.configuration.startupServices,
                        mcpServers: legacy.configuration.mcpServers,
                        events: legacy.configuration.events,
                        capabilities: NeoYCapabilityConfiguration()
                    )
                )
                try save(migrated)
                return NeoYControlPlaneLoadOutcome(document: migrated)
            }
            let document = try decoder.decode(NeoYControlPlaneDocument.self, from: data)
            try document.validate()
            return NeoYControlPlaneLoadOutcome(document: document)
        } catch {
            var outcome = NeoYControlPlaneLoadOutcome()
            if let envelope = try? JSONDecoder().decode(SchemaEnvelope.self, from: data) {
                outcome.health.schemaVersion = envelope.schemaVersion
            }
            try archive(data: data, reason: error.localizedDescription)
            try save(outcome.document)
            outcome.health.state = .degraded
            outcome.health.errorCode = "malformed_configuration"
            outcome.health.message = error.localizedDescription
            outcome.health.recovery = "invalid state was preserved, then replaced with validated defaults"
            return outcome
        }
    }

    func save(_ document: NeoYControlPlaneDocument) throws {
        do {
            try document.validate()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(document)
            let temporaryURL = directory.appendingPathComponent("control-plane.\(UUID().uuidString).tmp")
            try data.write(to: temporaryURL, options: .atomic)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
            }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch let error as NeoYControlPlaneError { throw error }
        catch { throw NeoYControlPlaneError.saveFailed(error.localizedDescription) }
    }

    private func archive(data: Data, reason: String) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: date()).replacingOccurrences(of: ":", with: "-")
        do { try data.write(to: directory.appendingPathComponent("control-plane-invalid-\(stamp).json"), options: .atomic) }
        catch {
            throw NeoYControlPlaneError.malformedState(
                "\(reason); the invalid copy could not be preserved: \(error.localizedDescription)")
        }
    }

    private struct SchemaEnvelope: Codable { let schemaVersion: Int }
    private struct V1Document: Codable {
        let schemaVersion: Int
        let configuration: V1Configuration
    }
    private struct V1Configuration: Codable { let diagnostics: NeoYDiagnosticsConfiguration }
    private struct V2Document: Codable {
        let schemaVersion: Int
        let configuration: V2Configuration
    }
    private struct V2Configuration: Codable {
        let diagnostics: NeoYDiagnosticsConfiguration
        let startupServices: [NeoYStartupServiceConfiguration]
        let mcpServers: [NeoYMCPServerConfiguration]
        let events: NeoYEventConfiguration
    }
}

actor NeoYControlPlaneService {
    private let store: any NeoYControlPlaneStoring
    private(set) var configuration = NeoYControlPlaneConfiguration()
    private(set) var health = NeoYControlPlaneHealth()

    init(store: any NeoYControlPlaneStoring) {
        self.store = store
        do {
            let outcome = try store.loadOrCreate()
            configuration = outcome.document.configuration
            health = outcome.health
        } catch {
            health.state = .degraded
            health.errorCode = "configuration_unavailable"
            health.message = error.localizedDescription
            health.recovery = "resolve application state access, then retry the configuration command"
        }
    }

    func currentHealth() -> NeoYControlPlaneHealth { health }
    func currentConfiguration() -> NeoYControlPlaneConfiguration { configuration }

    func setDiagnosticsEnabled(_ enabled: Bool) throws -> NeoYControlPlaneConfiguration {
        try mutate { $0.diagnostics.isEnabled = enabled }
    }

    func setDiagnostics(_ setting: NeoYDiagnosticsSetting) throws -> NeoYControlPlaneConfiguration {
        try mutate {
            switch setting {
            case .level(let level): $0.diagnostics.level = level
            case .retentionDays(let days): $0.diagnostics.retentionDays = days
            }
        }
    }

    func upsertStartup(_ service: NeoYStartupServiceConfiguration) throws -> NeoYControlPlaneConfiguration {
        try service.validate()
        return try mutate {
            $0.startupServices.removeAll { $0.name == service.name }
            $0.startupServices.append(service)
            $0.startupServices.sort { $0.name < $1.name }
        }
    }

    func removeStartup(_ name: String) throws -> NeoYControlPlaneConfiguration {
        try mutateExisting(kind: "startup service", name: name, keyPath: \NeoYControlPlaneConfiguration.startupServices)
    }

    func updateStartup(_ name: String, transform: (inout NeoYStartupServiceConfiguration) throws -> Void) throws -> NeoYControlPlaneConfiguration {
        try mutate {
            guard let index = $0.startupServices.firstIndex(where: { $0.name == name }) else {
                throw NeoYControlPlaneError.missingItem(kind: "startup service", name: name)
            }
            try transform(&$0.startupServices[index])
        }
    }

    func upsertMCP(_ server: NeoYMCPServerConfiguration) throws -> NeoYControlPlaneConfiguration {
        try server.validate()
        return try mutate {
            $0.mcpServers.removeAll { $0.name == server.name }
            $0.mcpServers.append(server)
            $0.mcpServers.sort { $0.name < $1.name }
        }
    }

    func removeMCP(_ name: String) throws -> NeoYControlPlaneConfiguration {
        try mutateExisting(kind: "MCP server", name: name, keyPath: \NeoYControlPlaneConfiguration.mcpServers)
    }

    func setMCPEnabled(_ name: String, enabled: Bool) throws -> NeoYControlPlaneConfiguration {
        try mutate {
            guard let index = $0.mcpServers.firstIndex(where: { $0.name == name }) else {
                throw NeoYControlPlaneError.missingItem(kind: "MCP server", name: name)
            }
            $0.mcpServers[index].isEnabled = enabled
        }
    }

    func setEvent(_ kind: NeoYImportantEventKind, enabled: Bool) throws -> NeoYControlPlaneConfiguration {
        try mutate { $0.events.set(kind, enabled: enabled) }
    }

    func setCapability(_ capability: NeoYOptionalCapability, enabled: Bool) throws -> NeoYControlPlaneConfiguration {
        try mutate { $0.capabilities.set(capability, enabled: enabled) }
    }

    private func mutateExisting<T>(
        kind: String, name: String,
        keyPath: WritableKeyPath<NeoYControlPlaneConfiguration, [T]>
    ) throws -> NeoYControlPlaneConfiguration where T: Sendable {
        try mutate { configuration in
            let before = configuration[keyPath: keyPath].count
            if T.self == NeoYStartupServiceConfiguration.self {
                configuration.startupServices.removeAll { $0.name == name }
            } else if T.self == NeoYMCPServerConfiguration.self {
                configuration.mcpServers.removeAll { $0.name == name }
            }
            guard configuration[keyPath: keyPath].count != before else {
                throw NeoYControlPlaneError.missingItem(kind: kind, name: name)
            }
        }
    }

    private func mutate(_ transform: (inout NeoYControlPlaneConfiguration) throws -> Void) throws -> NeoYControlPlaneConfiguration {
        if health.state == .degraded, health.errorCode == "configuration_unavailable" {
            throw NeoYControlPlaneError.unsupportedWhileDegraded(
                "configuration is degraded; resolve the reported state before changing settings")
        }
        var updated = configuration
        try transform(&updated)
        try updated.validate()
        let document = NeoYControlPlaneDocument(configuration: updated)
        do {
            try store.save(document)
            configuration = updated
            health = NeoYControlPlaneHealth()
            return updated
        } catch {
            health.state = .degraded
            health.errorCode = "configuration_save_failed"
            health.message = error.localizedDescription
            health.recovery = "the in-memory change was rejected; verify storage access and retry"
            throw error
        }
    }
}
