import AVFoundation
import Foundation

enum DemoPrimitive: String, CaseIterable, Codable, Sendable {
    case step
    case spotlight
    case annotate
    case caption
    case say
    case cursor
    case highlight
    case clear
    case pause
    case resume
    case wait
    case startRecording = "start_recording"
    case stopRecording = "stop_recording"
}

struct DemoTarget: Codable, Equatable, Sendable {
    var rect: CGRect?
    var path: String?
    var label: String?
    var role: String?

    enum CodingKeys: String, CodingKey {
        case rect
        case path
        case label
        case role
    }

    init(rect: CGRect? = nil, path: String? = nil, label: String? = nil, role: String? = nil) {
        self.rect = rect
        self.path = path
        self.label = label
        self.role = role
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rect = try? values.decode(CGRect.self, forKey: .rect)
        path = try? values.decode(String.self, forKey: .path)
        label = try? values.decode(String.self, forKey: .label)
        role = try? values.decode(String.self, forKey: .role)
    }

    var summary: String {
        if let rect {
            return "rect(\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height)))"
        }
        if let path { return "element:\(path)" }
        if let label { return "label:\(label)" }
        return "unresolved"
    }
}

struct DemoEvent: Codable, Equatable, Sendable {
    var sequence: Int
    var primitive: DemoPrimitive
    var elapsedMS: Int
    var target: String?
    var text: String?
    var durationMS: Int?
    var status: String

    enum CodingKeys: String, CodingKey {
        case sequence
        case primitive
        case elapsedMS = "elapsed_ms"
        case target
        case text
        case durationMS = "duration_ms"
        case status
    }
}

@MainActor
final class DemoTimeline {
    private(set) var events: [DemoEvent] = []
    private(set) var isPaused = false
    private var startedAt: Date?
    private let clock: @Sendable () -> Date

    init(clock: @escaping @Sendable () -> Date = Date.init) {
        self.clock = clock
    }

    var isActive: Bool { startedAt != nil }

    func start() {
        events.removeAll()
        isPaused = false
        startedAt = clock()
        _ = append(.startRecording, status: "started")
    }

    func record(
        _ primitive: DemoPrimitive,
        target: DemoTarget? = nil,
        text: String? = nil,
        durationMS: Int? = nil,
        status: String = "completed"
    ) throws -> DemoEvent {
        guard isActive else {
            throw DemoRecorderError.message("Call start_recording before demo primitives")
        }
        if primitive == .resume && !isPaused {
            throw DemoRecorderError.message("Demo timeline is not paused")
        }
        if primitive != .pause && primitive != .resume && isPaused {
            throw DemoRecorderError.message("Demo timeline is paused")
        }
        if primitive == .pause { isPaused = true }
        if primitive == .resume { isPaused = false }
        return append(primitive, target: target, text: text, durationMS: durationMS, status: status)
    }

    func finish(outputReference: String?) -> [DemoEvent] {
        append(.stopRecording, status: "completed")
        isPaused = false
        startedAt = nil
        return events
    }

    private func append(
        _ primitive: DemoPrimitive,
        target: DemoTarget? = nil,
        text: String? = nil,
        durationMS: Int? = nil,
        status: String
    ) -> DemoEvent {
        let event = DemoEvent(
            sequence: events.count,
            primitive: primitive,
            elapsedMS: elapsedMilliseconds,
            target: target.map(\.summary),
            text: text,
            durationMS: durationMS,
            status: status
        )
        events.append(event)
        return event
    }

    private var elapsedMilliseconds: Int {
        guard let startedAt else { return 0 }
        return Int(max(0, clock().timeIntervalSince(startedAt) * 1000))
    }
}
