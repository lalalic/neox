import AppIntents
import Foundation

/// Batch-runs on-device Vision analysis over recent library assets and
/// persists the results keyed by asset id, so `media.search` (`has_label`,
/// `has_text`, `with_people`) and `media.meta` serve the knowledge without
/// re-analyzing. No reasoning here: pick window + run + report.
struct AnalyzeMediaIntent: AppIntent {
    static let title: LocalizedStringResource = "Analyze Media"
    static var description: IntentDescription {
        IntentDescription(
            "Analyzes recent photos and videos on-device (labels, text, people) so search and metadata tools can use the results.",
            categoryName: "Agent"
        )
    }
    static let openAppWhenRun = true

    @Parameter(title: "Days", description: "How far back to analyze (0 = whole library)", default: 7)
    var days: Int

    @Parameter(title: "Re-analyze", description: "Redo assets that were already analyzed", default: false)
    var redo: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        // Device support check: probe (fast) if startup hasn't already.
        let caps = VisionCaps.summary.indexing ? VisionCaps.summary : VisionCaps.probe()
        guard caps.indexing else {
            return .result(value: "Error: this device doesn't support on-device vision analysis",
                           dialog: "This device can't run on-device media analysis.")
        }
        let liveTaskID = UUID()
        NeoxLiveActivityManager.shared.start(id: liveTaskID, title: "Analyzing photos", kind: .photoAnalysis)
        let summary = await VisionIndexer.run(days: max(days, 0), redo: redo, limit: 2000)
        NeoxLiveActivityManager.shared.end(id: liveTaskID)
        if summary.failed == -1 {
            return .result(value: "Error: another analysis run is already in progress",
                           dialog: "An analysis run is already in progress.")
        }
        if summary.failed == -2 {
            return .result(value: "Error: photo library access denied",
                           dialog: "Photo library access is denied — allow it in Settings › Privacy & Security › Photos.")
        }
        let text = """
        Vision index updated: \(summary.indexed) analyzed, \(summary.skipped) skipped, \
        \(summary.failed) failed. Library knowledge: \(summary.totalIndexed) assets indexed.
        """
        return .result(
            value: text,
            dialog: "Analyzed \(summary.indexed) assets (\(summary.totalIndexed) indexed in total)."
        )
    }
}
