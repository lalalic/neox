import AVFoundation
import Foundation
import ImageIO
import Photos
import Speech
import UIKit
import Vision

/// On-device intelligence tools: deep metadata, thumbnails, Vision analysis
/// (classify / OCR / people), visual similarity, video frame sampling and
/// speech transcription. Everything runs locally — no network APIs.
///
/// Images (thumbnails, frames) are written to the /files/ serving directory so
/// agents fetch them by URL; results are compact JSON, never base64.
enum VisionMediaTools {

    // MARK: - Tool surface

    static func tools(exportsDir: URL) -> [ToolDefinition] {
        try? FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)
        return [
            ToolDefinition(
                name: "media.meta",
                description: "Full metadata for one asset: EXIF (camera, lens, ISO, exposure), GPS coordinates, format, size, dates. Richer than media_search rows.",
                parameters: MediaTools.schema([
                    "id": MediaTools.stringProp("Asset localIdentifier from media_search"),
                ], required: ["id"]),
                handler: { args in
                    guard let id = MediaTools.str(args, "id") else { return "Error: 'id' required" }
                    return await meta(id: id)
                }
            ),
            ToolDefinition(
                name: "media.thumbnail",
                description: "Generate a JPEG preview of an asset, served at /files/. Returns {url, width, height}. max_side bounds resolution (default 1024).",
                parameters: MediaTools.schema([
                    "id": MediaTools.stringProp("Asset localIdentifier"),
                    "max_side": MediaTools.intProp("Max pixel edge of the longest side (default 1024)"),
                ], required: ["id"]),
                handler: { args in
                    await thumbnail(args: args, exportsDir: exportsDir)
                }
            ),
            ToolDefinition(
                name: "vision.classify",
                description: "Classify image content on-device. Returns ranked scene classes with confidence, e.g. beach/sunset/dog. query filters labels by keyword.",
                parameters: MediaTools.schema([
                    "id": MediaTools.stringProp("Asset localIdentifier"),
                    "query": MediaTools.stringProp("Only return labels containing this keyword (case-insensitive)"),
                    "max_results": MediaTools.intProp("Max classes returned (default 12)"),
                ], required: ["id"]),
                handler: { args in
                    await classify(args: args)
                }
            ),
            ToolDefinition(
                name: "vision.ocr",
                description: "Recognize text in an image (screenshots, documents, signs) on-device. Returns lines with confidence.",
                parameters: MediaTools.schema([
                    "id": MediaTools.stringProp("Asset localIdentifier"),
                ], required: ["id"]),
                handler: { args in
                    guard let id = MediaTools.str(args, "id") else { return "Error: 'id' required" }
                    return await ocr(id: id)
                }
            ),
            ToolDefinition(
                name: "vision.detect_people",
                description: "Detect people in an image: face count, per-face boxes + landmark groups, and full-body regions where visible.",
                parameters: MediaTools.schema([
                    "id": MediaTools.stringProp("Asset localIdentifier"),
                ], required: ["id"]),
                handler: { args in
                    guard let id = MediaTools.str(args, "id") else { return "Error: 'id' required" }
                    return await detectPeople(id: id)
                }
            ),
            ToolDefinition(
                name: "vision.similarity",
                description: "Find library assets visually similar to a reference (on-device feature-print embeddings). Returns ranked {id, distance} ascending. days bounds the scan window; scan cost grows with it.",
                parameters: MediaTools.schema([
                    "id": MediaTools.stringProp("Reference asset localIdentifier"),
                    "limit": MediaTools.intProp("Max matches (default 20)"),
                    "days": MediaTools.intProp("Scan window in days (default 365)"),
                ], required: ["id"]),
                handler: { args in
                    guard let id = MediaTools.str(args, "id") else { return "Error: 'id' required" }
                    return await similarity(id: id,
                                            limit: max(MediaTools.intOpt(args, "limit") ?? 20, 1),
                                            days: MediaTools.intOpt(args, "days") ?? 365)
                }
            ),
            ToolDefinition(
                name: "video.sample_frames",
                description: "Sample frames from a video, serve as JPEGs at /files/. Returns per-frame {t_s, url}. count = evenly spaced frames (default 6, max 30); interval_s overrides count.",
                parameters: MediaTools.schema([
                    "id": MediaTools.stringProp("Video asset localIdentifier"),
                    "count": MediaTools.intProp("Number of frames (default 6, max 30)"),
                    "interval_s": MediaTools.doubleProp("Exact interval in seconds (overrides count)"),
                    "max_side": MediaTools.intProp("Max pixel edge per frame (default 1280)"),
                ], required: ["id"]),
                handler: { args in
                    await sampleFrames(args: args, exportsDir: exportsDir)
                }
            ),
            ToolDefinition(
                name: "video.transcribe",
                description: "Transcribe speech from a video's audio track on-device (Speech framework). Returns {text, segments:[{start_s, end_s, text}]}. language hint e.g. en-US, zh-CN.",
                parameters: MediaTools.schema([
                    "id": MediaTools.stringProp("Video asset localIdentifier"),
                    "language": MediaTools.stringProp("BCP-47 language hint (default en-US)"),
                ], required: ["id"]),
                handler: { args in
                    guard let id = MediaTools.str(args, "id") else { return "Error: 'id' required" }
                    return await transcribe(id: id, language: MediaTools.str(args, "language") ?? "en-US")
                }
            ),
        ]
    }

    // MARK: - media.meta

    private static func meta(id: String) async -> String {
        switch await MediaTools.asset(id: id) {
        case .failed(let text): return text
        case .found(let asset):
            var out = MediaTools.describeBase(asset)
            out["gps"] = gpsDict(asset)
            out["exif"] = await exifDict(asset)
            return MediaTools.jsonString(out)
        }
    }

    private static func gpsDict(_ asset: PHAsset) -> [String: Any]? {
        guard let loc = asset.location else { return nil }
        var dict: [String: Any] = [
            "latitude": round(loc.coordinate.latitude * 1e6) / 1e6,
            "longitude": round(loc.coordinate.longitude * 1e6) / 1e6,
        ]
        if loc.altitude != 0 { dict["altitude_m"] = round(loc.altitude * 10) / 10 }
        if loc.speed >= 0 { dict["speed_mps"] = round(loc.speed * 10) / 10 }
        return dict
    }

    /// Real EXIF/TIFF/GPS sections by reading the original file (handles iCloud).
    private static func exifDict(_ asset: PHAsset) async -> [String: Any] {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("meta-\(UUID().uuidString).\(asset.mediaType == .video ? "mov" : "jpg")")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try await MediaTools.writeOriginal(asset: asset, to: tmp)
        } catch {
            return ["error": error.localizedDescription]
        }
        var dict: [String: Any] = [:]
        if asset.mediaType == .video {
            for item in AVURLAsset(url: tmp).metadata {
                if let key = item.commonKey?.rawValue, let value = item.value {
                    dict[key] = String(describing: value)
                }
            }
        } else {
            guard let src = CGImageSourceCreateWithURL(tmp as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else {
                return dict
            }
            for key in ["{Exif}", "{TIFF}", "{GPS}", "{IPTC}"] {
                if let section = props[key] as? [String: Any] {
                    dict[key] = section
                }
            }
            for key in ["PixelWidth", "PixelHeight", "Depth", "ColorSpace", "Orientation"] {
                if let v = props[key] { dict[key] = v }
            }
        }
        return dict
    }

    // MARK: - media.thumbnail

    private static func thumbnail(args: JSONValue, exportsDir: URL) async -> String {
        guard let id = MediaTools.str(args, "id") else { return "Error: 'id' required" }
        let maxSide = CGFloat(max(MediaTools.intOpt(args, "max_side") ?? 1024, 64))
        switch await MediaTools.asset(id: id) {
        case .failed(let text): return text
        case .found(let asset):
            do {
                let cg = try await MediaTools.requestImage(asset, maxSide: maxSide)
                let name = "\(MediaTools.safeName(asset))-\(Int(maxSide)).jpg"
                let dest = exportsDir.appendingPathComponent(name)
                guard let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.82) else {
                    return "Error: JPEG encode failed"
                }
                try data.write(to: dest)
                return MediaTools.jsonString([
                    "id": asset.localIdentifier,
                    "file": name,
                    "url": "/files/\(name)",
                    "width": cg.width,
                    "height": cg.height,
                    "size_bytes": data.count,
                ])
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - vision.classify

    private static func classify(args: JSONValue) async -> String {
        guard let id = MediaTools.str(args, "id") else { return "Error: 'id' required" }
        let query = MediaTools.str(args, "query")
        let maxResults = max(MediaTools.intOpt(args, "max_results") ?? 12, 1)
        switch await MediaTools.asset(id: id) {
        case .failed(let text): return text
        case .found(let asset):
            do {
                let cg = try await MediaTools.requestImage(asset, maxSide: 1024)
                let request = VNClassifyImageRequest()
                let handler = VNImageRequestHandler(cgImage: cg, orientation: MediaTools.orientation(from: asset))
                try handler.perform([request])
                let classes: [[String: Any]] = (request.results ?? [])
                    .filter { $0.confidence >= 0.2 }
                    .filter { query == nil || $0.identifier.localizedCaseInsensitiveContains(query!) }
                    .sorted { $0.confidence > $1.confidence }
                    .prefix(maxResults)
                    .map { ["label": $0.identifier, "confidence": r3($0.confidence)] }
                return MediaTools.jsonString(["classes": classes])
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - vision.ocr

    private static func ocr(id: String) async -> String {
        switch await MediaTools.asset(id: id) {
        case .failed(let text): return text
        case .found(let asset):
            do {
                let cg = try await MediaTools.requestImage(asset, maxSide: 1600)
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                let handler = VNImageRequestHandler(cgImage: cg, orientation: MediaTools.orientation(from: asset))
                try handler.perform([request])
                let lines: [[String: Any]] = (request.results ?? []).flatMap { obs -> [[String: Any]] in
                    guard let text = obs.topCandidates(1).first else { return [] }
                    return [["text": text.string, "confidence": r3(text.confidence)]]
                }
                return MediaTools.jsonString(["line_count": lines.count, "lines": lines])
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - vision.detect_people

    private static func detectPeople(id: String) async -> String {
        switch await MediaTools.asset(id: id) {
        case .failed(let text): return text
        case .found(let asset):
            do {
                let cg = try await MediaTools.requestImage(asset, maxSide: 1600)
                let faces = VNDetectFaceRectanglesRequest()
                let bodies = VNDetectHumanRectanglesRequest()
                bodies.upperBodyOnly = false
                let handler = VNImageRequestHandler(cgImage: cg, orientation: MediaTools.orientation(from: asset))
                try handler.perform([faces, bodies])
                let faceItems: [[String: Any]] = (faces.results ?? []).map { obs in
                    var f: [String: Any] = ["box": normalizedBox(obs.boundingBox)]
                    if let nose = obs.landmarks?.nose, let left = obs.landmarks?.leftEye, let right = obs.landmarks?.rightEye {
                        f["landmarks"] = ["nose": points(nose), "left_eye": points(left), "right_eye": points(right)]
                    }
                    return f
                }
                let bodyItems: [[String: Any]] = (bodies.results ?? []).map {
                    ["box": normalizedBox($0.boundingBox), "confidence": r3($0.confidence)]
                }
                return MediaTools.jsonString(["face_count": faceItems.count, "faces": faceItems, "bodies": bodyItems])
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        }
    }

    private static func normalizedBox(_ box: CGRect) -> [String: Double] {
        ["x": r3(box.minX), "y": r3(box.minY), "w": r3(box.width), "h": r3(box.height)]
    }

    private static func points(_ region: VNFaceLandmarkRegion2D?) -> [[Double]]? {
        guard let region else { return nil }
        return region.normalizedPoints.map { [r3($0.x), r3($0.y)] }
    }

    // MARK: - vision.similarity

    private static func similarity(id: String, limit: Int, days: Int) async -> String {
        switch await MediaTools.asset(id: id) {
        case .failed(let text): return text
        case .found(let ref):
            do {
                let refCG = try await MediaTools.requestImage(ref, maxSide: 768)
                guard let refPrint = try await featurePrint(cgImage: refCG, orientation: MediaTools.orientation(from: ref)) else {
                    return "Error: could not compute reference feature print"
                }

                let options = PHFetchOptions()
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                options.predicate = NSPredicate(
                    format: "creationDate > %@",
                    Date().addingTimeInterval(-Double(days) * 86_400) as NSDate)
                let fetch = PHAsset.fetchAssets(with: options)

                var scored: [(id: String, distance: Float, asset: PHAsset)] = []
                for i in 0..<fetch.count {
                    let candidate = fetch.object(at: i)
                    guard candidate.localIdentifier != ref.localIdentifier,
                          candidate.mediaType == ref.mediaType else { continue }
                    guard let cg = try? await MediaTools.requestImage(candidate, maxSide: 512),
                          let print = try? await featurePrint(cgImage: cg, orientation: MediaTools.orientation(from: candidate)) else { continue }
                    var distance: Float = 0
                    try print.computeDistance(&distance, to: refPrint)
                    scored.append((candidate.localIdentifier, distance, candidate))
                }
                let matches: [[String: Any]] = scored
                    .sorted { $0.distance < $1.distance }
                    .prefix(limit)
                    .map { item in
                        ["id": item.id, "distance": r3(item.distance),
                         "filename": (item.asset.value(forKey: "filename") as? String) ?? "",
                         "created": item.asset.creationDate.map { MediaTools.iso8601.string(from: $0) } ?? ""]
                    }
                return MediaTools.jsonString(["reference": id, "scanned": fetch.count, "matches": matches])
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        }
    }

    private static func featurePrint(cgImage: CGImage, orientation: CGImagePropertyOrientation) throws -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
        try handler.perform([request])
        return request.results?.first
    }

    // MARK: - video.sample_frames

    private static func sampleFrames(args: JSONValue, exportsDir: URL) async -> String {
        guard let id = MediaTools.str(args, "id") else { return "Error: 'id' required" }
        let count = min(max(MediaTools.intOpt(args, "count") ?? 6, 1), 30)
        let maxSide = CGFloat(max(MediaTools.intOpt(args, "max_side") ?? 1280, 64))
        switch await MediaTools.asset(id: id) {
        case .failed(let text): return text
        case .found(let asset):
            guard asset.mediaType == .video else { return "Error: asset is not a video" }

            // Materialize original (iCloud-aware), generate frames from the local file.
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("frames-\(UUID().uuidString).mov")
            defer { try? FileManager.default.removeItem(at: tmp) }
            do { try await MediaTools.writeOriginal(asset: asset, to: tmp) } catch {
                return "Error: \(error.localizedDescription)"
            }

            let duration = asset.duration
            let interval = MediaTools.doubleOpt(args, "interval_s") ?? (duration / Double(count))
            guard interval > 0.05 else { return "Error: interval too small" }

            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: tmp))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxSide, height: maxSide)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.3, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.3, preferredTimescale: 600)

            let base = MediaTools.safeName(asset)
            var frames: [[String: Any]] = []
            var t = interval * 0.5
            var index = 0
            while t < duration && index < 30 {
                do {
                    let cg = try generator.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil)
                    let name = "\(base)-frame\(String(format: "%02d", index)).jpg"
                    let dest = exportsDir.appendingPathComponent(name)
                    if let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.8) {
                        try? data.write(to: dest)
                        frames.append([
                            "t_s": r2(t),
                            "file": name,
                            "url": "/files/\(name)",
                            "width": cg.width,
                            "height": cg.height,
                        ])
                    }
                } catch {
                    frames.append(["t_s": r2(t), "error": error.localizedDescription])
                }
                index += 1
                t += interval
            }
            return MediaTools.jsonString([
                "duration_s": r1(duration),
                "frames": frames,
            ])
        }
    }

    // MARK: - video.transcribe

    private static func transcribe(id: String, language: String) async -> String {
        switch await MediaTools.asset(id: id) {
        case .failed(let text): return text
        case .found(let asset):
            guard asset.mediaType == .video else { return "Error: asset is not a video" }

            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: break
            case .notDetermined:
                let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
                }
                guard granted else {
                    return "Error: speech recognition permission denied. Enable in Settings → Privacy & Security → Speech Recognition."
                }
            default:
                return "Error: speech recognition permission denied. Enable in Settings → Privacy & Security → Speech Recognition."
            }
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)), recognizer.isAvailable else {
                return "Error: no speech recognizer available for \(language)"
            }

            // Materialize audio (iCloud-aware)
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("speech-\(UUID().uuidString).mov")
            defer { try? FileManager.default.removeItem(at: tmp) }
            do { try await MediaTools.writeOriginal(asset: asset, to: tmp) } catch {
                return "Error: \(error.localizedDescription)"
            }

            return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
                let request = SFSpeechURLRecognitionRequest(url: tmp)
                request.shouldReportPartialResults = false
                if recognizer.supportsOnDeviceRecognition {
                    request.requiresOnDeviceRecognition = true
                }
                recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        cont.resume(returning: "Error: \(error.localizedDescription)")
                    } else if let result, result.isFinal {
                        let segments: [[String: Any]] = result.bestTranscription.segments.map {
                            ["start_s": r1($0.timestamp),
                             "end_s": r1($0.timestamp + $0.duration),
                             "text": $0.substring]
                        }
                        cont.resume(returning: MediaTools.jsonString([
                            "language": language,
                            "text": result.bestTranscription.formattedString,
                            "segments": segments,
                        ]))
                    }
                }
            }
        }
    }
}

// MARK: - Rounding helpers

private func r3(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
private func r3(_ value: CGFloat) -> Double { (Double(value) * 1000).rounded() / 1000 }
private func r3(_ value: Float) -> Double { (Double(value) * 1000).rounded() / 1000 }

private func r1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
private func r2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
