import AVFoundation
import Foundation
import Photos
import Vision

// MARK: - Data model

/// One indexed label from on-device image classification.
struct IndexedLabel: Codable, Sendable {
    let label: String
    let confidence: Double
}

/// Compact per-asset Vision analysis persisted by the media index.
/// Kept small on purpose: enough to make search/meta smart without
/// storing boxes, landmarks or full transcripts.
struct VisionAnalysis: Codable, Sendable {
    let analyzedAt: Date
    let labels: [IndexedLabel]
    /// Recognized text (OCR), joined; nil when nothing readable.
    let ocrText: String?
    let faceCount: Int
    let personCount: Int
}

/// Immutable box for handing non-Sendable values across a continuation.
/// Safe here: the value is written once, before resume, and read once after.
private struct SendableBox<T>: @unchecked Sendable {
    let value: T
}

/// Summary of a batch index run.
struct IndexSummary: Sendable {
    var indexed = 0
    var skipped = 0
    var failed = 0
    var totalIndexed = 0
}

// MARK: - Store

/// Persistent per-asset Vision analysis store (`assetId → VisionAnalysis`).
/// Backs `media.search` filters (`has_label` / `has_text` / `with_people`),
/// row enrichment and `media.meta` analysis sections. One JSON file in
/// Application Support, loaded lazily, saved atomically.
actor VisionIndexStore {
    static let shared = VisionIndexStore()

    private var index: [String: VisionAnalysis] = [:]
    private var loaded = false

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Neox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("vision-index.json")
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        index = (try? decoder.decode([String: VisionAnalysis].self, from: data)) ?? [:]
    }

    func analysis(for id: String) -> VisionAnalysis? {
        loadIfNeeded()
        return index[id]
    }

    var totalCount: Int {
        loadIfNeeded()
        return index.count
    }

    func insert(_ analysis: VisionAnalysis, for id: String) {
        loadIfNeeded()
        index[id] = analysis
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(index) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Batch indexer

/// Analyzes library assets (images + a representative video frame each) with a
/// single Vision pass (classify + OCR + faces + bodies) and persists results
/// via `VisionIndexStore`. Runs off the main actor; one batch at a time.
enum VisionIndexer {

    private static let gate = RunGate()

    /// Async-safe re-entrancy guard: one batch at a time, no locks held
    /// across suspensions.
    private actor RunGate {
        private var isRunning = false
        func tryEnter() -> Bool {
            if isRunning { return false }
            isRunning = true
            return true
        }
        func exit() { isRunning = false }
    }

    /// Index un-analyzed (or all, with `redo`) assets created within `days`.
    /// `limit` bounds the batch; `progress` receives assets completed so far.
    /// Returns `failed == -1` when another run is in progress, `-2` when the
    /// photo library is not accessible.
    static func run(days: Int, redo: Bool, limit: Int,
                    progress: (@Sendable (Int) -> Void)? = nil) async -> IndexSummary {
        guard await gate.tryEnter() else {
            var s = IndexSummary()
            s.failed = -1  // sentinel: another run in progress
            return s
        }
        defer { Task { await gate.exit() } }

        let status = await MediaTools.requestAccess()
        guard status == .authorized || status == .limited else {
            var s = IndexSummary()
            s.failed = -2  // sentinel: no library access
            return s
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if days > 0 {
            let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
            options.predicate = NSPredicate(format: "creationDate > %@", cutoff as NSDate)
        }
        let fetch = PHAsset.fetchAssets(with: options)
        let store = VisionIndexStore.shared
        var summary = IndexSummary()

        let budget = min(max(limit, 1), 5000)
        var done = 0
        for i in 0..<fetch.count {
            if summary.indexed + summary.skipped >= budget { break }
            let asset = fetch.object(at: i)
            let id = asset.localIdentifier
            if !redo, await store.analysis(for: id) != nil {
                summary.skipped += 1
                continue
            }
            do {
                let analysis = try await analyze(asset: asset)
                await store.insert(analysis, for: id)
                summary.indexed += 1
                // Checkpoint periodically so a long run never loses everything.
                if summary.indexed % 25 == 0 { await store.save() }
            } catch {
                summary.failed += 1
            }
            done += 1
            if let progress, done % 10 == 0 { progress(done) }
        }
        await store.save()
        summary.totalIndexed = await store.totalCount
        return summary
    }

    /// Single-asset Vision pass: classification labels, OCR text, face/body
    /// counts. Images load at 1024px; videos use one sampled frame.
    static func analyze(asset: PHAsset) async throws -> VisionAnalysis {
        let cg: CGImage
        if asset.mediaType == .video {
            cg = try await firstVideoFrame(asset)
        } else {
            cg = try await MediaTools.requestImage(asset, maxSide: 1024)
        }
        return try runVision(cg: cg)
    }

    private static func runVision(cg: CGImage) throws -> VisionAnalysis {
        let classify = VNClassifyImageRequest()
        let ocr = VNRecognizeTextRequest()
        // .accurate: the index feeds content search — recall beats speed here
        // (batches are incremental, each asset analyzed once).
        ocr.recognitionLevel = .accurate
        ocr.usesLanguageCorrection = true
        let faces = VNDetectFaceRectanglesRequest()
        let bodies = VNDetectHumanRectanglesRequest()
        bodies.upperBodyOnly = false

        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up)
        try handler.perform([classify, ocr, faces, bodies])

        let labels: [IndexedLabel] = (classify.results ?? [])
            .filter { $0.confidence >= 0.2 }
            .sorted { $0.confidence > $1.confidence }
            .prefix(15)
            .map { IndexedLabel(label: $0.identifier, confidence: Double(round($0.confidence * 1000) / 1000)) }

        let text = (ocr.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
        let trimmed = text.isEmpty ? nil : String(text.prefix(2000))

        return VisionAnalysis(
            analyzedAt: Date(),
            labels: labels,
            ocrText: trimmed,
            faceCount: faces.results?.count ?? 0,
            personCount: bodies.results?.count ?? 0
        )
    }

    /// Fast representative frame: middle of the video with loose tolerance.
    private static func firstVideoFrame(_ asset: PHAsset) async throws -> CGImage {
        let options = PHVideoRequestOptions()
        options.version = .current
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .fastFormat
        let avAsset: AVAsset = try await withCheckedThrowingContinuation { cont in
            var finished = false
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { av, _, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                guard !degraded, !finished else { return }
                finished = true
                if let av {
                    cont.resume(returning: SendableBox(value: av))
                } else {
                    cont.resume(throwing: NSError(domain: "Neox", code: 20,
                        userInfo: [NSLocalizedDescriptionKey: "could not load video"]))
                }
            }
        }.value
        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let mid = CMTime(seconds: min(1.0, asset.duration * 0.5), preferredTimescale: 600)
        return try await withCheckedThrowingContinuation { cont in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: mid)]) { _, cg, _, result, error in
                if result == .succeeded, let cg {
                    cont.resume(returning: cg)
                } else {
                    cont.resume(throwing: error ?? NSError(domain: "Neox", code: 21,
                        userInfo: [NSLocalizedDescriptionKey: "frame extraction failed"]))
                }
            }
        }
    }
}

// MARK: - Search/meta integration helpers

enum VisionIndexQuery {
    /// Does the asset's index entry match has_label/has_text/with_people filters?
    static func matches(_ analysis: VisionAnalysis?,
                        hasLabel: String?, hasText: String?, withPeople: Bool) -> Bool {
        guard let analysis else { return false }
        if let hasLabel,
           !analysis.labels.contains(where: { $0.label.localizedCaseInsensitiveContains(hasLabel) }) {
            return false
        }
        if let hasText,
           !((analysis.ocrText ?? "").localizedCaseInsensitiveContains(hasText)) {
            return false
        }
        if withPeople, analysis.faceCount == 0, analysis.personCount == 0 { return false }
        return true
    }

    /// Compact per-row enrichment for media.search results.
    static func rowSummary(_ analysis: VisionAnalysis) -> [String: Any] {
        var vision: [String: Any] = [
            "labels": analysis.labels.prefix(3).map { $0.label },
            "faces": analysis.faceCount,
        ]
        if analysis.ocrText != nil { vision["text"] = true }
        if analysis.personCount > analysis.faceCount { vision["people"] = analysis.personCount }
        return vision
    }
}
