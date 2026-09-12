import ActivityKit
import Foundation

struct NeoxActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var activeTaskCount: Int
        var status: NeoxActivityStatus
        var title: String?
        var progress: Double?
        var activityKind: NeoxActivityKind?
        var updatedAt: Date
    }

    var instanceID: String
}

enum NeoxActivityStatus: String, Codable, Hashable {
    case running, waiting, processing, completed, error
}

enum NeoxActivityKind: String, Codable, Hashable {
    case agent, photoAnalysis, videoProcessing, transcription, vision, transfer, other
}
