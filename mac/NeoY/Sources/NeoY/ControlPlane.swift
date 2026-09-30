import Foundation

enum NeoYControlPlaneSchema {
    static let currentVersion = 1
}

enum NeoYDiagnosticsLevel: String, Codable, CaseIterable, Sendable {
    case info
    case warning
    case error
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

struct NeoYControlPlaneConfiguration: Codable, Equatable, Sendable {
    var diagnostics = NeoYDiagnosticsConfiguration()

    func validate() throws {
        try diagnostics.validate()
    }
}

struct NeoYControlPlaneDocument: Codable, Equatable, Sendable {
    var schemaVersion = NeoYControlPlaneSchema.currentVersion
    var configuration = NeoYControlPlaneConfiguration()

    func validate() throws {
        guard schemaVersion == NeoYControlPlaneSchema.currentVersion else {
            throw NeoYControlPlaneError.unsupportedSchemaVersion(
                found: schemaVersion,
                expected: NeoYControlPlaneSchema.currentVersion
            )
        }
        try configuration.validate()
    }
}

enum NeoYControlPlaneState: String, Codable, Sendable {
    case ready
    case degraded
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
    case saveFailed(String)
    case unsupportedWhileDegraded(String)

    var errorDescription: String? {
        switch self {
        case .unreadableState(let reason):
            return "configuration state could not be read: \(reason)"
        case .malformedState(let reason):
            return "configuration state was malformed: \(reason)"
        case .unsupportedSchemaVersion(let found, let expected):
            return "unsupported configuration schema version \(found); expected \(expected)"
        case .invalidRetentionDays(let value):
            return "retention-days must be an integer from 1 through 365; got \(value)"
        case .invalidDiagnosticsLevel(let value):
            return "level must be one of \(NeoYDiagnosticsLevel.allCases.map(\.rawValue).joined(separator: ", ")); got '\(value)'"
        case .invalidDiagnosticsProperty(let value):
            return "unknown diagnostics property '\(value)'; supported properties: level, retention-days"
        case .saveFailed(let reason):
            return "configuration state could not be saved: \(reason)"
        case .unsupportedWhileDegraded(let reason):
            return reason
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
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw NeoYControlPlaneError.unreadableState(error.localizedDescription)
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let document = NeoYControlPlaneDocument()
            try save(document)
            return NeoYControlPlaneLoadOutcome(document: document)
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw NeoYControlPlaneError.unreadableState(error.localizedDescription)
        }

        do {
            let decoder = JSONDecoder()
            let document = try decoder.decode(NeoYControlPlaneDocument.self, from: data)
            try document.validate()
            return NeoYControlPlaneLoadOutcome(document: document)
        } catch {
            var outcome = NeoYControlPlaneLoadOutcome()
            if let envelope = try? JSONDecoder().decode(SchemaEnvelope.self, from: data),
               envelope.schemaVersion != NeoYControlPlaneSchema.currentVersion {
                outcome.health.schemaVersion = envelope.schemaVersion
            }
            try archive(data: data, reason: error.localizedDescription)
            try save(outcome.document)

            var health = outcome.health
            health.state = .degraded
            health.errorCode = "malformed_configuration"
            health.message = error.localizedDescription
            health.recovery = "invalid state was preserved, then replaced with validated defaults"
            outcome.health = health
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
        } catch let error as NeoYControlPlaneError {
            throw error
        } catch {
            throw NeoYControlPlaneError.saveFailed(error.localizedDescription)
        }
    }

    private func archive(data: Data, reason: String) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: date())
            .replacingOccurrences(of: ":", with: "-")
        let archiveURL = directory.appendingPathComponent("control-plane-invalid-\(timestamp).json")

        do {
            try data.write(to: archiveURL, options: .atomic)
        } catch {
            throw NeoYControlPlaneError.malformedState(
                "\(reason); the invalid copy could not be preserved: \(error.localizedDescription)"
            )
        }
    }

    private struct SchemaEnvelope: Codable {
        let schemaVersion: Int
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
            var degradedHealth = NeoYControlPlaneHealth()
            degradedHealth.state = .degraded
            degradedHealth.errorCode = "configuration_unavailable"
            degradedHealth.message = error.localizedDescription
            degradedHealth.recovery = "resolve application state access, then retry the configuration command"
            health = degradedHealth
        }
    }

    func currentHealth() -> NeoYControlPlaneHealth {
        health
    }

    func currentConfiguration() -> NeoYControlPlaneConfiguration {
        configuration
    }

    func setDiagnosticsEnabled(_ isEnabled: Bool) throws -> NeoYControlPlaneConfiguration {
        try mutate { configuration in
            configuration.diagnostics.isEnabled = isEnabled
        }
        return configuration
    }

    func setDiagnostics(_ setting: NeoYDiagnosticsSetting) throws -> NeoYControlPlaneConfiguration {
        try mutate { configuration in
            switch setting {
            case .level(let level):
                configuration.diagnostics.level = level
            case .retentionDays(let days):
                configuration.diagnostics.retentionDays = days
            }
        }
        return configuration
    }

    private func mutate(_ transform: (inout NeoYControlPlaneConfiguration) -> Void) throws {
        if health.state == .degraded, health.errorCode == "configuration_unavailable" {
            throw NeoYControlPlaneError.unsupportedWhileDegraded(
                "configuration is degraded; resolve the reported state before changing settings"
            )
        }

        var updated = configuration
        transform(&updated)
        try updated.validate()
        let document = NeoYControlPlaneDocument(schemaVersion: health.schemaVersion, configuration: updated)

        do {
            try store.save(document)
            configuration = updated
            health = NeoYControlPlaneHealth(schemaVersion: document.schemaVersion)
        } catch {
            var failedHealth = NeoYControlPlaneHealth(schemaVersion: document.schemaVersion)
            failedHealth.state = .degraded
            failedHealth.errorCode = "configuration_save_failed"
            failedHealth.message = error.localizedDescription
            failedHealth.recovery = "the in-memory change was rejected; verify storage access and retry"
            health = failedHealth
            throw error
        }
    }
}
