import AVFoundation
import Foundation
import Photos
import UniformTypeIdentifiers

/// MCP tools exposing the device photo/video library to desktop agents.
///
/// - `media.search` — enumerate assets with metadata (compact JSON)
/// - `media.export` — export originals (or 720p/1080p video transcodes) to
///   files the MCPServer serves at `GET /files/<name>` with Range support.
///
/// Tools return text/URLs only — never base64 media (videos would OOM iOS).
public enum MediaTools {

    // MARK: - Tool surface

    public static func tools(exportsDir: URL) -> [ToolDefinition] {
        try? FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)
        return [
            ToolDefinition(
                name: "media.search",
                description: """
                Search the iPhone photo/video library. Returns JSON with asset metadata: \
                id, filename, media_type, pixel dimensions, duration (videos), creation date, \
                file size. Sort: newest first. Use ids with media.export.
                """,
                parameters: schema([
                    "media_type": stringProp("Filter by media type", enumVals: ["all", "image", "video"]),
                    "days": intProp("Only assets from the last N days"),
                    "after": stringProp("Only assets created after this ISO8601 date, e.g. 2026-09-01T00:00:00Z"),
                    "before": stringProp("Only assets created before this ISO8601 date"),
                    "album": stringProp("Only assets in the album with this exact name"),
                    "favorited": boolProp("Only favorited assets"),
                    "limit": intProp("Max assets to return (default 50, max 500)"),
                    "offset": intProp("Skip this many results for pagination (see next_offset in response)"),
                ]),
                handler: { args in
                    try await search(args: args)
                }
            ),
            ToolDefinition(
                name: "media.export",
                description: """
                Export photo/video assets (ids from media.search) to files served by this \
                phone's MCP server. Returns JSON with a `url` per asset — fetch it with HTTP \
                Range requests (curl -C -). preset=720p/1080p transcodes videos with \
                AVAssetExportSession to shrink the transfer; images always export original.
                """,
                parameters: schema([
                    "ids": arrayProp("Asset localIdentifiers from media.search (one or more)"),
                    "preset": stringProp("Video export preset: original (default), 720p, 1080p", enumVals: ["original", "720p", "1080p"]),
                ], required: ["ids"]),
                handler: { args in
                    try await export(args: args, exportsDir: exportsDir)
                }
            ),
        ]
    }

    /// Shared authorization flow (also used by the status screen).
    static func requestAccess() async -> PHAuthorizationStatus {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .notDetermined else { return status }
        return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    /// Fetch one asset by id; failure carries user-readable error text.
    enum AssetResult {
        case found(PHAsset)
        case failed(String)
    }

    static func asset(id: String) async -> AssetResult {
        let status = await requestAccess()
        guard status == .authorized || status == .limited else {
            return .failed("Error: photo library access denied (status \(status.rawValue)). Grant access on the phone: Settings → Privacy & Security → Photos.")
        }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard fetch.count > 0 else { return .failed("Error: asset \(id) not found") }
        return .found(fetch.object(at: 0))
    }

    /// Load an asset's image, optionally downscaled to maxSide on the longest edge.
    /// Returned CGImage is already upright (PHImageManager applies orientation).
    static func requestImage(_ asset: PHAsset, maxSide: CGFloat?) async throws -> CGImage {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        var target = CGSize(width: asset.pixelWidth, height: asset.pixelHeight)
        if let maxSide {
            options.resizeMode = .fast
            target = scaledSize(pixel: target, maxSide: maxSide)
        }
        return try await withCheckedThrowingContinuation { cont in
            var finished = false
            PHImageManager.default().requestImage(for: asset, targetSize: target, contentMode: .aspectFit, options: options) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                guard !degraded, !finished else { return }
                finished = true
                if let image, let cg = image.cgImage {
                    cont.resume(returning: cg)
                } else {
                    cont.resume(throwing: NSError(domain: "Neox", code: 10,
                        userInfo: [NSLocalizedDescriptionKey: "could not load image"]))
                }
            }
        }
    }

    private static func scaledSize(pixel: CGSize, maxSide: CGFloat) -> CGSize {
        let longest = max(pixel.width, pixel.height)
        guard longest > maxSide, longest > 0 else { return pixel }
        let scale = maxSide / longest
        return CGSize(width: pixel.width * scale, height: pixel.height * scale)
    }

    /// Vision orientation for images produced by requestImage(_:maxSide:).
    /// PHImageManager delivers upright images, so .up is always correct there.
    static func orientation(from asset: PHAsset) -> CGImagePropertyOrientation {
        .up
    }

    // MARK: - media.search

    private static func search(args: JSONValue) async throws -> String {
        let status = await requestAccess()
        guard status == .authorized || status == .limited else {
            return "Error: photo library access denied (status \(status.rawValue)). Grant access on the phone: Settings → Privacy & Security → Photos."
        }

        let mediaType = str(args, "media_type") ?? "all"
        let albumName = str(args, "album")
        let favorited = bool(args, "favorited")
        let limit = min(max(intArg(args, "limit", default: 50), 1), 500)
        let offset = max(intArg(args, "offset", default: 0), 0)

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        var predicates: [NSPredicate] = []
        switch mediaType {
        case "image":
            predicates.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue))
        case "video":
            predicates.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue))
        default:
            break
        }
        if let days = intOpt(args, "days"), days > 0 {
            let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
            predicates.append(NSPredicate(format: "creationDate > %@", cutoff as NSDate))
        }
        if let after = dateArg(args, "after") {
            predicates.append(NSPredicate(format: "creationDate >= %@", after as NSDate))
        }
        if let before = dateArg(args, "before") {
            predicates.append(NSPredicate(format: "creationDate < %@", before as NSDate))
        }
        if favorited {
            predicates.append(NSPredicate(format: "isFavorite == YES"))
        }
        if !predicates.isEmpty {
            options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        }

        let fetch: PHFetchResult<PHAsset>
        if let albumName {
            let collections = PHAssetCollection.fetchAssetCollections(
                with: .album, subtype: .any, options: nil)
            var match: PHAssetCollection?
            collections.enumerateObjects { collection, _, _ in
                if match == nil, collection.localizedTitle == albumName { match = collection }
            }
            guard let album = match else {
                var available: [String] = []
                collections.enumerateObjects { collection, _, _ in
                    if let t = collection.localizedTitle, available.count < 30 { available.append(t) }
                }
                return "Error: album '\(albumName)' not found. Albums: \(available.joined(separator: ", "))"
            }
            fetch = PHAsset.fetchAssets(in: album, options: options)
        } else {
            fetch = PHAsset.fetchAssets(with: options)
        }

        var assets: [[String: Any]] = []
        if offset < fetch.count {
            let end = min(fetch.count, offset + limit)
            for i in offset..<end {
                assets.append(describeBase(fetch.object(at: i)))
            }
        }

        var result: [String: Any] = [
            "matched": fetch.count,
            "returned": assets.count,
            "assets": assets,
        ]
        if fetch.count > offset + assets.count {
            result["next_offset"] = offset + assets.count
        }
        return Self.jsonString(result)
    }

    static func describeBase(_ asset: PHAsset) -> [String: Any] {
        var item: [String: Any] = [
            "id": asset.localIdentifier,
            "media_type": asset.mediaType == .video ? "video" : asset.mediaType == .image ? "image" : "other",
            "width": asset.pixelWidth,
            "height": asset.pixelHeight,
            "favorite": asset.isFavorite,
        ]
        if let filename = asset.value(forKey: "filename") as? String {
            item["filename"] = filename
        }
        if asset.mediaType == .video {
            item["duration_s"] = round(asset.duration * 10) / 10
        }
        if let created = asset.creationDate {
            item["created"] = Self.iso8601.string(from: created)
        }
        if let size = fileSize(of: asset) {
            item["size_bytes"] = size
        }
        return item
    }

    private static func fileSize(of asset: PHAsset) -> Int64? {
        let resources = PHAssetResource.assetResources(for: asset)
        let resource = resources.first { $0.type == .photo }
            ?? resources.first { $0.type == .video }
            ?? resources.first
        guard let resource else { return nil }
        let size = resource.value(forKey: "fileSize") as? Int64
        return size
    }

    // MARK: - media.export

    private static func export(args: JSONValue, exportsDir: URL) async throws -> String {
        let status = await requestAccess()
        guard status == .authorized || status == .limited else {
            return "Error: photo library access denied (status \(status.rawValue))."
        }

        var ids: [String] = []
        if case .object(let dict) = args, case .array(let arr)? = dict["ids"] {
            for case .string(let s) in arr { ids.append(s) }
        } else if case .object(let dict) = args, case .string(let s)? = dict["ids"] {
            ids.append(s)
        }
        guard !ids.isEmpty else { return "Error: 'ids' (array of asset ids from media.search) is required." }

        let preset = str(args, "preset") ?? "original"
        guard ["original", "720p", "1080p"].contains(preset) else {
            return "Error: preset must be original, 720p or 1080p"
        }

        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        guard fetch.count > 0 else { return "Error: no assets found for the given ids" }

        var exported: [[String: Any]] = []
        var errors: [String] = []
        for i in 0..<fetch.count {
            let asset = fetch.object(at: i)
            do {
                exported.append(try await exportOne(asset, preset: preset, exportsDir: exportsDir))
            } catch {
                errors.append("\(asset.localIdentifier): \(error.localizedDescription)")
            }
        }

        var result: [String: Any] = ["exports": exported]
        if !errors.isEmpty { result["errors"] = errors }
        return Self.jsonString(result)
    }

    private static func exportOne(_ asset: PHAsset, preset: String, exportsDir: URL) async throws -> [String: Any] {
        let isVideo = asset.mediaType == .video
        let base = safeName(asset)
        let dest: URL

        if isVideo && preset != "original" {
            dest = exportsDir.appendingPathComponent("\(base)-\(preset).mp4")
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try await transcodeVideo(asset: asset, preset: preset, to: dest)
        } else {
            let ext = originalExtension(asset)
            dest = exportsDir.appendingPathComponent("\(base).\(ext)")
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try await writeOriginal(asset: asset, to: dest)
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

        var item: [String: Any] = [
            "id": asset.localIdentifier,
            "file": dest.lastPathComponent,
            "url": "/files/\(dest.lastPathComponent)",
            "size_bytes": size,
        ]
        if isVideo && preset != "original" { item["preset"] = preset }
        if let filename = asset.value(forKey: "filename") as? String {
            item["original_name"] = filename
        }
        return item
    }

    /// Stream the original bytes out of the photo library (iCloud assets download on demand).
    static func writeOriginal(asset: PHAsset, to url: URL) async throws {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .photo })
            ?? resources.first(where: { $0.type == .video })
            ?? resources.first(where: { $0.type == .fullSizePhoto })
            ?? resources.first(where: { $0.type == .fullSizeVideo })
            ?? resources.first else {
            throw NSError(domain: "Neox", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no PHAssetResource for asset"])
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: nil) { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }
    }

    private static func transcodeVideo(asset: PHAsset, preset: String, to url: URL) async throws {
        // 1) Materialize the original video (handles iCloud-on-demand) into a temp
        //    file — AVAsset isn't Sendable, so it must never cross a continuation.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pb-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await writeOriginal(asset: asset, to: tmp)

        // 2) Transcode with AVAssetExportSession
        let presetName = preset == "1080p" ? AVAssetExportPreset1920x1080 : AVAssetExportPreset1280x720
        let avAsset = AVURLAsset(url: tmp)
        guard let session = AVAssetExportSession(asset: avAsset, presetName: presetName) else {
            throw NSError(domain: "Neox", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "no AVAssetExportSession for preset \(presetName)"])
        }
        try await session.export(to: url, as: AVFileType.mp4)
    }

    // MARK: - Helpers

    /// Filesystem-safe name, stable per asset: "video-AB12CD34EF56".
    static func safeName(_ asset: PHAsset) -> String {
        let kind = asset.mediaType == .video ? "video" : "photo"
        let idPart = asset.localIdentifier.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        return "\(kind)-\(idPart.suffix(12).lowercased())"
    }

    private static func originalExtension(_ asset: PHAsset) -> String {
        if let filename = asset.value(forKey: "filename") as? String {
            let ext = (filename as NSString).pathExtension.lowercased()
            if !ext.isEmpty { return ext }
        }
        return asset.mediaType == .video ? "mov" : "jpg"
    }

    static func str(_ args: JSONValue, _ key: String) -> String? {
        guard case .object(let dict) = args, case .string(let s)? = dict[key] else { return nil }
        return s
    }

    private static func intArg(_ args: JSONValue, _ key: String, default def: Int) -> Int {
        intOpt(args, key) ?? def
    }

    static func intOpt(_ args: JSONValue, _ key: String) -> Int? {
        guard case .object(let dict) = args else { return nil }
        if case .int(let i)? = dict[key] { return i }
        if case .double(let d)? = dict[key] { return Int(d) }
        return nil
    }

    static func doubleOpt(_ args: JSONValue, _ key: String) -> Double? {
        guard case .object(let dict) = args, case .double(let d)? = dict[key] else { return nil }
        return d
    }

    private static func bool(_ args: JSONValue, _ key: String) -> Bool {
        guard case .object(let dict) = args, case .bool(let b)? = dict[key] else { return false }
        return b
    }

    private static func dateArg(_ args: JSONValue, _ key: String) -> Date? {
        guard let s = str(args, key) else { return nil }
        return Self.iso8601.date(from: s) ?? Self.iso8601DateOnly.date(from: s)
    }

    static nonisolated(unsafe) let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static nonisolated(unsafe) let iso8601DateOnly: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()

    static func jsonString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return "{\"error\":\"json serialization failed\"}"
        }
        return String(data: data, encoding: .utf8) ?? "{\"error\":\"json encoding failed\"}"
    }

    // MARK: - Schema builders

    static func schema(_ props: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(props),
            "required": .array(required.map { .string($0) }),
        ])
    }

    static func stringProp(_ desc: String, enumVals: [String]? = nil) -> JSONValue {
        var obj: [String: JSONValue] = [
            "type": .string("string"),
            "description": .string(desc),
        ]
        if let enumVals { obj["enum"] = .array(enumVals.map { .string($0) }) }
        return .object(obj)
    }

    static func intProp(_ desc: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(desc)])
    }

    static func doubleProp(_ desc: String) -> JSONValue {
        .object(["type": .string("number"), "description": .string(desc)])
    }

    private static func boolProp(_ desc: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(desc)])
    }

    private static func arrayProp(_ desc: String) -> JSONValue {
        .object([
            "type": .string("array"),
            "items": .object(["type": .string("string")]),
            "description": .string(desc),
        ])
    }
}
