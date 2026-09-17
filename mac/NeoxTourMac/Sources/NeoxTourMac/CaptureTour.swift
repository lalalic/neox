import AVFoundation
import AppKit
import Combine
import Foundation
import SwiftUI

struct CaptureTourManifest: Codable, Sendable, Equatable {
    var version: Int = 1
    var tourID: String
    var title: String
    var shots: [CaptureShot]

    enum CodingKeys: String, CodingKey { case version, tourID = "tour_id", title, shots }

    func validated() throws -> CaptureTourManifest {
        guard version == 1 else { throw TourError.invalid("version must be 1") }
        guard !tourID.isEmpty, !title.isEmpty, !shots.isEmpty else {
            throw TourError.invalid("tour_id, title, and at least one shot are required")
        }
        var ids = Set<String>()
        for shot in shots {
            guard !shot.id.isEmpty, ids.insert(shot.id).inserted else {
                throw TourError.invalid("shot ids must be non-empty and unique")
            }
            if let duration = shot.targetDurationS, duration < 0 {
                throw TourError.invalid("target_duration_s cannot be negative")
            }
        }
        return self
    }
}

struct CaptureShot: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var title: String
    var kind: String = "talking_head"
    var instruction: String?
    var script: String?
    var targetDurationS: Double?
    var camera: String = "front"
    var orientation: String = "portrait"
    var lens: String = "default"
    var framing: CaptureFraming?
    var quality: CaptureQuality?
    var notes: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id, title, kind, instruction, script, targetDurationS = "target_duration_s"
        case camera, orientation, lens, framing, quality, notes
    }
}

struct CaptureFraming: Codable, Sendable, Equatable {
    var subject: String?
    var guide: String?
    var position: String?
}

struct CaptureQuality: Codable, Sendable, Equatable {
    var faceRequired: Bool?
    var warnIfTooNear: Bool?
    var warnIfTooFar: Bool?
    var warnIfDark: Bool?
    var warnIfSoft: Bool?

    enum CodingKeys: String, CodingKey {
        case faceRequired = "face_required"
        case warnIfTooNear = "warn_if_too_near"
        case warnIfTooFar = "warn_if_too_far"
        case warnIfDark = "warn_if_dark"
        case warnIfSoft = "warn_if_soft"
    }
}

struct CaptureResult: Codable, Sendable, Equatable, Identifiable {
    var id: String { shotID }
    let shotID: String
    var status: String
    var takeCount: Int
    var actualDurationS: Double
    var createdAt: Date
    var mediaReference: String?
    var qualityWarnings: [String]

    enum CodingKeys: String, CodingKey {
        case shotID = "shot_id", status, takeCount = "take_count", actualDurationS = "actual_duration_s"
        case createdAt = "created_at", mediaReference = "media_reference", qualityWarnings = "quality_warnings"
    }
}

struct CaptureTourSession: Codable, Sendable, Equatable {
    let sessionID: String
    let manifest: CaptureTourManifest
    var state: String
    var currentIndex: Int
    var results: [CaptureResult]
    var startedAt: Date

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", manifest, state, currentIndex = "current_index", results, startedAt = "started_at"
    }
}

enum TourError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { message } else { nil } }
}

@MainActor
final class CaptureTourStore: ObservableObject {
    static let shared = CaptureTourStore()
    @Published private(set) var session: CaptureTourSession?

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NeoxTourMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("capture-tour.json")
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? decoder.decode(CaptureTourSession.self, from: data) {
            session = saved
        }
    }

    func start(_ manifest: CaptureTourManifest) throws -> CaptureTourSession {
        let valid = try manifest.validated()
        let value = CaptureTourSession(
            sessionID: UUID().uuidString,
            manifest: valid,
            state: "ready",
            currentIndex: 0,
            results: [],
            startedAt: Date()
        )
        session = value
        persist()
        return value
    }

    func begin() {
        guard var value = session else { return }
        value.state = "ready"
        session = value
        persist()
    }

    func cancel() {
        session = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    func update(_ value: CaptureTourSession) {
        session = value
        persist()
    }

    func statusJSON() -> String {
        guard let value = session else { return "{\"state\":\"idle\"}" }
        let accepted = value.results.filter { $0.status == "accepted" }.count
        let skipped = value.results.filter { $0.status == "skipped" }.count
        let results: [[String: Any]] = value.results.map {
            [
                "shot_id": $0.shotID,
                "status": $0.status,
                "take_count": $0.takeCount,
                "actual_duration_s": $0.actualDurationS,
                "created_at": ISO8601DateFormatter().string(from: $0.createdAt),
                "media_reference": $0.mediaReference ?? NSNull(),
                "quality_warnings": $0.qualityWarnings,
            ]
        }
        return Self.json([
            "state": value.state,
            "session_id": value.sessionID,
            "tour_id": value.manifest.tourID,
            "title": value.manifest.title,
            "current_shot": value.currentIndex < value.manifest.shots.count ? value.manifest.shots[value.currentIndex].id : NSNull(),
            "shot_index": value.currentIndex,
            "shot_count": value.manifest.shots.count,
            "accepted": accepted,
            "skipped": skipped,
            "remaining": max(0, value.manifest.shots.count - value.results.count),
            "results": results,
        ])
    }

    nonisolated static func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func persist() {
        guard let session, let data = try? encoder.encode(session) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

enum CaptureTourTools {
    static func tools() -> [ToolDefinition] {
        [
            ToolDefinition(
                name: "tour.start",
                description: "Validate and start a generic ordered Capture Tour manifest on this Mac.",
                parameters: schema([
                    "manifest": stringProp("JSON-encoded Capture Tour manifest")
                ], required: ["manifest"])
            ) { args in
                guard case .object(let object) = args,
                      case .string(let raw)? = object["manifest"] else {
                    return "Error: 'manifest' must be a JSON string"
                }
                do {
                    let manifest = try JSONDecoder().decode(CaptureTourManifest.self, from: Data(raw.utf8))
                    let value = try await MainActor.run { try CaptureTourStore.shared.start(manifest) }
                    return CaptureTourStore.json([
                        "state": value.state,
                        "session_id": value.sessionID,
                        "tour_id": value.manifest.tourID,
                        "shot_count": value.manifest.shots.count,
                    ])
                } catch {
                    return "Error: \(error.localizedDescription)"
                }
            },
            ToolDefinition(
                name: "tour.status",
                description: "Return Capture Tour progress and accepted shot-to-file references.",
                parameters: schema([:])
            ) { _ in await MainActor.run { CaptureTourStore.shared.statusJSON() } },
            ToolDefinition(
                name: "tour.cancel",
                description: "Cancel the active Capture Tour without deleting accepted media files.",
                parameters: schema([:])
            ) { _ in
                await MainActor.run { CaptureTourStore.shared.cancel() }
                return "{\"state\":\"idle\"}"
            },
        ]
    }

    private static func stringProp(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var object: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty { object["required"] = .array(required.map(JSONValue.string)) }
        return .object(object)
    }
}
