import AVFoundation
import AppKit
import ScreenCaptureKit

@MainActor
final class DemoRecorder: NSObject {
    static let shared = DemoRecorder()

    private(set) var state = "idle"
    private(set) var sessionID: String?
    private(set) var elapsed = 0.0
    private(set) var outputReference: String?
    private(set) var displayWidth = 0
    private(set) var displayHeight = 0

    private var stream: SCStream?
    private var videoWriter: DemoVideoWriter?
    private var systemRecording: AnyObject?
    private let captureQueue = DispatchQueue(label: "neox-demo-recorder.capture")
    private var outputURL: URL?
    private var startedAt: Date?
    private var display: SCDisplay?

    func start() async -> String {
        guard state != "recording" else { return statusJSON() }
        if state == "completed" || state == "error" { reset() }

        do {
            // Permission is intentionally requested here, on demand, rather than at launch.
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let selected = mainDisplay(in: content.displays) else {
                throw DemoRecorderError.message("No main display is available")
            }
            display = selected
            displayWidth = selected.width
            displayHeight = selected.height
            let id = UUID().uuidString
            sessionID = id
            let exports = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("NeoxTourMac/exports", isDirectory: true)
            try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
            let name = "demo-\(id).mov"
            outputURL = exports.appendingPathComponent(name)
            outputReference = "/files/\(name)"
            let filter = SCContentFilter(display: selected, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = selected.width
            configuration.height = selected.height
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.queueDepth = 3
            configuration.showsCursor = true

            guard let outputURL else { throw DemoRecorderError.message("Missing demo output URL") }
            let value = SCStream(filter: filter, configuration: configuration, delegate: nil)
            if #available(macOS 15.0, *) {
                let recorder = try DemoSystemRecording(outputURL: outputURL)
                try value.addRecordingOutput(recorder.output)
                systemRecording = recorder
            } else {
                let sink = DemoVideoWriter(outputURL: outputURL)
                try value.addStreamOutput(sink, type: .screen, sampleHandlerQueue: captureQueue)
                videoWriter = sink
            }
            stream = value
            startedAt = Date()
            elapsed = 0
            state = "recording"
            try await value.startCapture()
            return statusJSON()
        } catch {
            fail(error)
            return statusJSON()
        }
    }

    func stop() async -> String {
        guard state == "recording" else { return statusJSON() }
        do {
            if let stream { try await stream.stopCapture() }
            self.stream = nil
            if #available(macOS 15.0, *), let systemRecording = systemRecording as? DemoSystemRecording {
                elapsed = try await systemRecording.finish()
            } else if let videoWriter {
                elapsed = try await videoWriter.finish()
            } else {
                throw DemoRecorderError.message("No screen recording backend was configured")
            }
            self.systemRecording = nil
            self.videoWriter = nil
            state = "completed"
            DemoOverlayController.shared.clear(width: displayWidth, height: displayHeight)
        } catch {
            fail(error)
        }
        return statusJSON()
    }

    func cancel() async -> String {
        if let stream {
            try? await stream.stopCapture()
        }
        self.stream = nil
        if #available(macOS 15.0, *), let systemRecording = systemRecording as? DemoSystemRecording {
            systemRecording.cancel()
        }
        systemRecording = nil
        videoWriter?.cancel()
        videoWriter = nil
        DemoOverlayController.shared.clear(width: displayWidth, height: displayHeight)
        if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
        reset()
        return statusJSON()
    }

    func statusJSON() -> String {
        CaptureTourStore.json([
            "state": state,
            "session_id": (sessionID ?? NSNull()) as Any,
            "elapsed_s": max(0, state == "recording" ? Date().timeIntervalSince(startedAt ?? Date()) : elapsed),
            "output_reference": outputReference ?? NSNull(),
            "display_width": displayWidth,
            "display_height": displayHeight,
        ])
    }

    private func mainDisplay(in displays: [SCDisplay]) -> SCDisplay? {
        guard let mainID = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return displays.first
        }
        return displays.first(where: { $0.displayID == mainID }) ?? displays.first
    }

    private func reset() {
        state = "idle"
        sessionID = nil
        elapsed = 0
        outputReference = nil
        outputURL = nil
        startedAt = nil
        display = nil
        displayWidth = 0
        displayHeight = 0
    }

    private func fail(_ error: Error) {
        state = "error"
        elapsed = Date().timeIntervalSince(startedAt ?? Date())
        stream = nil
        if #available(macOS 15.0, *), let systemRecording = systemRecording as? DemoSystemRecording {
            systemRecording.cancel()
        }
        systemRecording = nil
        videoWriter?.cancel()
        videoWriter = nil
        outputReference = nil
        NSLog("Neox demo recorder error: %@", error.localizedDescription)
    }

}

@available(macOS 15.0, *)
private final class DemoSystemRecording: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
    private(set) var output: SCRecordingOutput!
    private var completion: CheckedContinuation<Double, Error>?
    private var result: Result<Double, Error>?

    init(outputURL: URL) throws {
        try? FileManager.default.removeItem(at: outputURL)
        let configuration = SCRecordingOutputConfiguration()
        configuration.outputURL = outputURL
        configuration.outputFileType = .mov
        configuration.videoCodecType = .h264
        super.init()
        self.output = SCRecordingOutput(configuration: configuration, delegate: self)
    }

    func finish() async throws -> Double {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation in
            if let result { continuation.resume(with: result) }
            else { completion = continuation }
        }
    }

    func cancel() {
        if result == nil { complete(.failure(DemoRecorderError.message("Demo recording cancelled"))) }
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {}

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        complete(.failure(error))
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        complete(.success(max(0, CMTimeGetSeconds(recordingOutput.recordedDuration))))
    }

    private func complete(_ value: Result<Double, Error>) {
        guard result == nil else { return }
        result = value
        if let completion {
            self.completion = nil
            completion.resume(with: value)
        }
    }
}

private final class DemoVideoWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    private let outputURL: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var firstPTS: CMTime?
    private var lastPTS: CMTime?
    private var failure: Error?

    init(outputURL: URL) {
        self.outputURL = outputURL
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer),
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw), status != .complete { return }

        do {
            if writer == nil { try configureWriter(for: sampleBuffer) }
            guard failure == nil, let writer, let input, writer.status == .writing else { return }
            guard input.isReadyForMoreMediaData else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if input.append(sampleBuffer) {
                if firstPTS == nil { firstPTS = pts }
                lastPTS = pts
            } else if let error = writer.error {
                failure = error
            }
        } catch {
            failure = error
        }
    }

    func finish() async throws -> Double {
        if let failure { throw failure }
        guard let writer, let input, writer.status == .writing else {
            throw DemoRecorderError.message("Screen capture produced no writable video frames")
        }
        input.markAsFinished()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                if writer.status == .completed { continuation.resume() }
                else { continuation.resume(throwing: writer.error ?? DemoRecorderError.message("Could not finalize demo recording")) }
            }
        }
        guard let firstPTS, let lastPTS else { return 0 }
        return max(0, CMTimeGetSeconds(CMTimeSubtract(lastPTS, firstPTS)))
    }

    func cancel() {
        input?.markAsFinished()
        writer?.cancelWriting()
        if FileManager.default.fileExists(atPath: outputURL.path) { try? FileManager.default.removeItem(at: outputURL) }
    }

    private func configureWriter(for sampleBuffer: CMSampleBuffer) throws {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw DemoRecorderError.message("Screen frame has no format description")
        }
        try? FileManager.default.removeItem(at: outputURL)
        let value = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(dimensions.width),
            AVVideoHeightKey: Int(dimensions.height),
        ])
        videoInput.expectsMediaDataInRealTime = true
        guard value.canAdd(videoInput) else { throw DemoRecorderError.message("Could not configure H.264 writer") }
        value.add(videoInput)
        guard value.startWriting() else { throw value.error ?? DemoRecorderError.message("Could not start writer") }
        value.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        writer = value
        input = videoInput
    }
}

@MainActor
final class DemoOverlayController {
    static let shared = DemoOverlayController()
    private var window: NSWindow?
    private var items: [String: DemoOverlayItem] = [:]
    private var clearTasks: [String: Task<Void, Never>] = [:]

    func clear(width: Int, height: Int) {
        clearTasks.values.forEach { $0.cancel() }
        clearTasks.removeAll()
        items.removeAll()
        redraw(width: width, height: height)
    }

    func update(kind: String, rect: CGRect?, text: String?, durationMS: Int?, width: Int, height: Int) throws {
        guard ["highlight", "spotlight", "caption", "clear"].contains(kind) else {
            throw DemoRecorderError.message("unknown overlay kind '\(kind)'")
        }
        if kind == "clear" {
            if let rect { items = items.filter { !$0.value.rect.intersects(rect) } } else { items.removeAll() }
            redraw(width: width, height: height)
            return
        }
        guard let rect, rect.width > 0, rect.height > 0,
              rect.minX >= 0, rect.minY >= 0,
              rect.maxX <= CGFloat(width), rect.maxY <= CGFloat(height) else {
            throw DemoRecorderError.message("rect must be inside the main display bounds")
        }
        let item = DemoOverlayItem(kind: kind, rect: rect, text: text)
        items[kind] = item
        redraw(width: width, height: height)
        clearTasks[kind]?.cancel()
        if let durationMS, durationMS > 0 {
            clearTasks[kind] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(durationMS))
                guard !Task.isCancelled else { return }
                self?.items.removeValue(forKey: kind)
                self?.redraw(width: width, height: height)
            }
        }
    }

    private func redraw(width: Int, height: Int) {
        guard let screen = NSScreen.main else { return }
        if window == nil {
            let value = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            value.isOpaque = false
            value.backgroundColor = .clear
            value.level = .screenSaver
            value.ignoresMouseEvents = true
            value.collectionBehavior = [.canJoinAllSpaces, .stationary]
            value.hasShadow = false
            value.isReleasedWhenClosed = false
            window = value
        }
        window?.setFrame(screen.frame, display: false)
        let view = DemoOverlayView(items: Array(items.values), displaySize: CGSize(width: width, height: height))
        window?.contentView = view
        if items.isEmpty { window?.orderOut(nil) } else { window?.orderFrontRegardless() }
    }
}

private struct DemoOverlayItem {
    let kind: String
    let rect: CGRect
    let text: String?
}

private final class DemoOverlayView: NSView {
    let items: [DemoOverlayItem]
    let displaySize: CGSize

    init(items: [DemoOverlayItem], displaySize: CGSize) {
        self.items = items
        self.displaySize = displaySize
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scaleX = bounds.width / displaySize.width
        let scaleY = bounds.height / displaySize.height
        for item in items {
            let rect = CGRect(x: item.rect.minX * scaleX,
                              y: bounds.height - item.rect.maxY * scaleY,
                              width: item.rect.width * scaleX,
                              height: item.rect.height * scaleY)
            switch item.kind {
            case "highlight":
                context.setStrokeColor(NSColor.systemYellow.cgColor)
                context.setLineWidth(4)
                context.stroke(rect.insetBy(dx: 2, dy: 2))
            case "spotlight":
                context.setFillColor(NSColor.black.withAlphaComponent(0.42).cgColor)
                context.fill(bounds)
                context.clear(rect)
                context.setStrokeColor(NSColor.systemYellow.cgColor)
                context.setLineWidth(3)
                context.stroke(rect)
            case "caption":
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: max(16, min(32, rect.height * 0.35)), weight: .semibold),
                    .foregroundColor: NSColor.white,
                    .backgroundColor: NSColor.black.withAlphaComponent(0.7),
                    .paragraphStyle: paragraph,
                ]
                (item.text ?? "").draw(in: rect.insetBy(dx: 8, dy: 4), withAttributes: attributes)
            default: break
            }
        }
    }
}

enum DemoRecorderError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { value } else { nil } }
}

enum DemoRecorderTools {
    static func tools() -> [ToolDefinition] {
        [
            ToolDefinition(name: "demo.start", description: "Start main-display H.264 screen capture.", parameters: schema([:])) { _ in
                await DemoRecorder.shared.start()
            },
            ToolDefinition(name: "demo.overlay", description: "Show or clear a click-through demo overlay on the recorded main display.", parameters: schema([
                "kind": stringProp("highlight, spotlight, caption, or clear"),
                "rect": .object(["type": .string("object"), "properties": .object(["x": .object(["type": .string("number")]), "y": .object(["type": .string("number")]), "width": .object(["type": .string("number")]), "height": .object(["type": .string("number")])])]),
                "text": stringProp("Optional caption text"),
                "duration_ms": .object(["type": .string("integer")]),
            ], required: ["kind"])) { args in
                do {
                    let values = try parseOverlay(args)
                    return try await MainActor.run {
                        try DemoOverlayController.shared.update(kind: values.kind, rect: values.rect, text: values.text, durationMS: values.durationMS,
                                                                width: DemoRecorder.shared.displayWidth, height: DemoRecorder.shared.displayHeight)
                        return DemoRecorder.shared.statusJSON()
                    }
                } catch { return "Error: \(error.localizedDescription)" }
            },
            ToolDefinition(name: "demo.status", description: "Return demo recorder state and output metadata.", parameters: schema([:])) { _ in
                await MainActor.run { DemoRecorder.shared.statusJSON() }
            },
            ToolDefinition(name: "demo.stop", description: "Stop capture and finalize the .mov export.", parameters: schema([:])) { _ in
                await DemoRecorder.shared.stop()
            },
            ToolDefinition(name: "demo.cancel", description: "Cancel capture and remove its unfinished export.", parameters: schema([:])) { _ in
                await DemoRecorder.shared.cancel()
            },
        ]
    }

    private static func parseOverlay(_ args: JSONValue) throws -> (kind: String, rect: CGRect?, text: String?, durationMS: Int?) {
        guard case .object(let object) = args, case .string(let kind)? = object["kind"] else {
            throw DemoRecorderError.message("'kind' is required")
        }
        var rect: CGRect?
        if case .object(let raw)? = object["rect"] {
            func number(_ key: String) -> CGFloat? {
                switch raw[key] { case .int(let v): return CGFloat(v); case .double(let v): return CGFloat(v); default: return nil }
            }
            guard let x = number("x"), let y = number("y"), let w = number("width"), let h = number("height") else {
                throw DemoRecorderError.message("rect requires numeric x, y, width, and height")
            }
            rect = CGRect(x: x, y: y, width: w, height: h)
        }
        let text = object["text"].flatMap { if case .string(let value) = $0 { value } else { nil } }
        let durationMS = object["duration_ms"].flatMap { if case .int(let value) = $0 { value } else { nil } }
        return (kind, rect, text, durationMS)
    }

    private static func stringProp(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var value: [String: JSONValue] = ["type": .string("object"), "properties": .object(properties)]
        if !required.isEmpty { value["required"] = .array(required.map(JSONValue.string)) }
        return .object(value)
    }
}
