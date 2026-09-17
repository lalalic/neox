@preconcurrency import AVFoundation
import Foundation
import SwiftUI
import UIKit
import Vision

// MARK: - Durable tour contract

struct CaptureTourManifest: Codable, Sendable, Equatable {
    var version: Int = 1
    var tourID: String
    var title: String
    var shots: [CaptureShot]

    enum CodingKeys: String, CodingKey { case version, tourID = "tour_id", title, shots }

    func validated() throws -> CaptureTourManifest {
        guard version == 1 else { throw TourError.invalid("version must be 1") }
        guard !tourID.isEmpty, !title.isEmpty, !shots.isEmpty else { throw TourError.invalid("tour_id, title, and at least one shot are required") }
        var ids = Set<String>()
        for shot in shots {
            guard !shot.id.isEmpty, ids.insert(shot.id).inserted else { throw TourError.invalid("shot ids must be non-empty and unique") }
            if let duration = shot.targetDurationS, duration < 0 { throw TourError.invalid("target_duration_s cannot be negative") }
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

struct CaptureFraming: Codable, Sendable, Equatable { var subject: String?; var guide: String?; var position: String? }
struct CaptureQuality: Codable, Sendable, Equatable {
    var faceRequired: Bool?
    var warnIfTooNear: Bool?
    var warnIfTooFar: Bool?
    var warnIfDark: Bool?
    var warnIfSoft: Bool?
    enum CodingKeys: String, CodingKey {
        case faceRequired = "face_required", warnIfTooNear = "warn_if_too_near", warnIfTooFar = "warn_if_too_far"
        case warnIfDark = "warn_if_dark", warnIfSoft = "warn_if_soft"
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
    enum CodingKeys: String, CodingKey { case sessionID = "session_id", manifest, state, currentIndex = "current_index", results, startedAt = "started_at" }
}

enum TourError: LocalizedError { case invalid(String); var errorDescription: String? { if case .invalid(let s) = self { return s }; return nil } }

@MainActor
final class CaptureTourStore: ObservableObject {
    static let shared = CaptureTourStore()
    @Published private(set) var session: CaptureTourSession?
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Neox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("capture-tour.json")
        encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL), let saved = try? decoder.decode(CaptureTourSession.self, from: data) { session = saved }
    }

    func start(_ manifest: CaptureTourManifest) throws -> CaptureTourSession {
        let valid = try manifest.validated()
        let value = CaptureTourSession(sessionID: UUID().uuidString, manifest: valid, state: "pending", currentIndex: 0, results: [], startedAt: Date())
        session = value; persist(); return value
    }

    func begin() { guard var value = session else { return }; value.state = "ready"; session = value; persist() }
    func cancel() { session = nil; try? FileManager.default.removeItem(at: fileURL) }
    func update(_ value: CaptureTourSession) { session = value; persist() }

    func statusJSON() -> String {
        guard let value = session else { return "{\"state\":\"idle\"}" }
        let accepted = value.results.filter { $0.status == "accepted" }.count
        let skipped = value.results.filter { $0.status == "skipped" }.count
        let object: [String: Any] = ["state": value.state, "session_id": value.sessionID, "tour_id": value.manifest.tourID, "title": value.manifest.title,
                "current_shot": value.currentIndex < value.manifest.shots.count ? value.manifest.shots[value.currentIndex].id : NSNull(),
                "shot_index": value.currentIndex, "shot_count": value.manifest.shots.count, "accepted": accepted, "skipped": skipped,
                "remaining": max(0, value.manifest.shots.count - value.results.count), "results": value.results.map { result in
                    ["shot_id": result.shotID, "status": result.status, "take_count": result.takeCount, "actual_duration_s": result.actualDurationS,
                     "created_at": ISO8601DateFormatter().string(from: result.createdAt), "media_reference": result.mediaReference as Any,
                     "quality_warnings": result.qualityWarnings]
                }]
        return MediaTools.jsonString(object)
    }

    private func persist() { guard let session, let data = try? encoder.encode(session) else { return }; try? data.write(to: fileURL, options: .atomic) }
}

enum CaptureTourTools {
    static func tools() -> [ToolDefinition] {
        [
            ToolDefinition(name: "tour.start", description: "Validate and start a generic ordered Capture Tour manifest. The human completes recording in Neox.", parameters: MediaTools.schema(["manifest": MediaTools.stringProp("JSON-encoded Capture Tour manifest")], required: ["manifest"]), handler: { args in
                guard case .object(let object) = args, case .string(let raw)? = object["manifest"] else { return "Error: 'manifest' must be a JSON string" }
                do { let manifest = try JSONDecoder().decode(CaptureTourManifest.self, from: Data(raw.utf8)); let value = try await MainActor.run { try CaptureTourStore.shared.start(manifest) }; return MediaTools.jsonString(["state": value.state, "session_id": value.sessionID, "tour_id": value.manifest.tourID, "shot_count": value.manifest.shots.count]) }
                catch { return "Error: \(error.localizedDescription)" }
            }),
            ToolDefinition(name: "tour.status", description: "Return Capture Tour progress and accepted shot-to-file references.", parameters: MediaTools.schema([:]), handler: { _ in await MainActor.run { CaptureTourStore.shared.statusJSON() } }),
            ToolDefinition(name: "tour.cancel", description: "Cancel the active Capture Tour without deleting unrelated media.", parameters: MediaTools.schema([:]), handler: { _ in await MainActor.run { CaptureTourStore.shared.cancel() }; return "{\"state\":\"idle\"}" })
        ]
    }
}

// MARK: - Camera capture

@MainActor
final class CaptureRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var lastURL: URL?
    @Published private(set) var qualityWarning = ""
    let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let analysisQueue = DispatchQueue(label: "com.neox.capture-quality", qos: .userInitiated)
    private var timer: Timer?
    private var startedAt: Date?
    private var quality = CaptureQuality()
    private var orientation = "portrait"

    func prepare(camera: String, orientation: String = "portrait", lens: String = "default", quality: CaptureQuality? = nil) async {
        guard await AVCaptureDevice.requestAccess(for: .video) else { return }
        self.quality = quality ?? CaptureQuality()
        self.orientation = orientation
        session.beginConfiguration()
        for input in session.inputs {
            if let videoInput = input as? AVCaptureDeviceInput, videoInput.device.hasMediaType(.video) { session.removeInput(videoInput) }
        }
        let position: AVCaptureDevice.Position = camera.lowercased() == "back" ? .back : .front
        let (device, lensFallback) = CaptureRecorder.device(position: position, lens: lens)
        if let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) { session.addInput(input) }
        if await AVCaptureDevice.requestAccess(for: .audio), let microphone = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: microphone), session.canAddInput(audioInput) { session.addInput(audioInput) }
        if session.canAddOutput(output) { session.addOutput(output) }
        if session.canAddOutput(videoOutput) { videoOutput.setSampleBufferDelegate(self, queue: analysisQueue); session.addOutput(videoOutput) }
        session.commitConfiguration()
        applyPreferences(to: output.connections, lensFallback: lensFallback)
        applyPreferences(to: videoOutput.connections, lensFallback: lensFallback)
        DispatchQueue.global(qos: .userInitiated).async { [session] in if !session.isRunning { session.startRunning() } }
    }

    private static func device(position: AVCaptureDevice.Position, lens: String) -> (AVCaptureDevice?, Bool) {
        let type: AVCaptureDevice.DeviceType
        switch lens.lowercased() { case "ultrawide", "ultra_wide": type = .builtInUltraWideCamera; case "telephoto": type = .builtInTelephotoCamera; default: type = .builtInWideAngleCamera }
        if let preferred = AVCaptureDevice.default(type, for: .video, position: position) { return (preferred, false) }
        return (AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) ?? AVCaptureDevice.default(for: .video), lens.lowercased() != "default" && lens.lowercased() != "wide")
    }

    private func applyPreferences(to connections: [AVCaptureConnection], lensFallback: Bool) {
        let value: AVCaptureVideoOrientation
        switch orientation.lowercased() { case "landscape_left": value = .landscapeLeft; case "landscape_right": value = .landscapeRight; case "portrait_upside_down": value = .portraitUpsideDown; default: value = .portrait }
        for connection in connections where connection.isVideoOrientationSupported { connection.videoOrientation = value }
        if lensFallback { qualityWarning = "Requested lens unavailable" }
    }

    func start(to url: URL) { guard !output.isRecording else { return }; lastURL = nil; startedAt = Date(); elapsed = 0; output.startRecording(to: url, recordingDelegate: self); isRecording = true; timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in Task { @MainActor in guard let self, let startedAt = self.startedAt else { return }; self.elapsed = Date().timeIntervalSince(startedAt) } } }
    func stop() { guard output.isRecording else { return }; output.stopRecording(); timer?.invalidate(); timer = nil }
}

extension CaptureRecorder: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let request = VNDetectFaceRectanglesRequest(); try? VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([request])
        let faces = (request.results as? [VNFaceObservation]) ?? []
        let luminance = CaptureRecorder.luminance(of: buffer)
        Task { @MainActor [weak self] in
            guard let self, self.quality.faceRequired == true || self.quality.warnIfTooNear == true || self.quality.warnIfTooFar == true || self.quality.warnIfDark == true else { return }
            if self.quality.warnIfDark == true && luminance < 0.18 { self.qualityWarning = "More light"; return }
            guard let face = faces.first else { if self.quality.faceRequired == true { self.qualityWarning = "Face not detected" }; return }
            let area = face.boundingBox.width * face.boundingBox.height
            if self.quality.warnIfTooNear == true && area > 0.42 { self.qualityWarning = "Move back a little"; return }
            if self.quality.warnIfTooFar == true && area < 0.08 { self.qualityWarning = "Move closer"; return }
            self.qualityWarning = abs(face.boundingBox.midX - 0.5) > 0.16 || abs(face.boundingBox.midY - 0.5) > 0.18 ? "Center your face" : ""
        }
    }

    nonisolated private static func luminance(of buffer: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return 1 }
        let bytes = base.assumingMemoryBound(to: UInt8.self), width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0), rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let stepY = max(1, height / 8), stepX = max(1, width / 8); var total = 0; var count = 0
        for y in stride(from: 0, to: height, by: stepY) { for x in stride(from: 0, to: width, by: stepX) { total += Int(bytes[y * rowBytes + x]); count += 1 } }
        return Float(total) / Float(max(1, count * 255))
    }
}

@MainActor
extension CaptureRecorder: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        Task { @MainActor [weak self] in
            self?.isRecording = false
            self?.lastURL = error == nil ? outputFileURL : nil
        }
    }
}

struct CapturePreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView { let view = PreviewView(); view.preview.session = session; view.preview.videoGravity = .resizeAspectFill; return view }
    func updateUIView(_ view: PreviewView, context: Context) { view.preview.session = session }
    final class PreviewView: UIView { let preview = AVCaptureVideoPreviewLayer(); override init(frame: CGRect) { super.init(frame: frame); layer.addSublayer(preview) }; required init?(coder: NSCoder) { fatalError() }; override func layoutSubviews() { super.layoutSubviews(); preview.frame = bounds } }
}
