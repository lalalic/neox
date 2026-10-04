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
    private(set) var lastError: String?

    private var stream: SCStream?
    private var videoWriter: DemoVideoWriter?
    private var systemRecording: AnyObject?
    private let captureQueue = DispatchQueue(label: "neox-demo-recorder.capture")
    private var outputURL: URL?
    private var startedAt: Date?
    private var display: SCDisplay?
    let timeline = DemoTimeline()
    private var lastEvents: [DemoEvent] = []
    private let speech = DemoSpeechSpeaker()

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
                .appendingPathComponent("NeoY/exports", isDirectory: true)
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
            // demo.say speaks from NeoY itself, so keep current-process audio in the
            // system capture and persist narration in the resulting MOV.
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = false

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
            timeline.start()
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

    func startSemanticRecording() async -> String {
        if state == "recording" { return statusJSON() }
        return await start()
    }

    func perform(
        _ primitive: DemoPrimitive,
        target: DemoTarget? = nil,
        text: String? = nil,
        durationMS: Int? = nil
    ) async throws -> String {
        guard state == "recording" else {
            throw DemoRecorderError.message("start_recording is required before \(primitive.rawValue)")
        }
        let resolvedTarget = try target.map { try resolved(for: $0) }
        switch primitive {
        case .step:
            break
        case .spotlight:
            try overlay(kind: primitive.rawValue, rect: resolvedTarget?.rect, text: text, durationMS: durationMS)
        case .annotate:
            try overlay(kind: primitive.rawValue, rect: resolvedTarget?.rect, text: text ?? "", durationMS: durationMS ?? 2_500)
        case .caption:
            try overlay(kind: "caption", rect: captionRect, text: text, durationMS: durationMS)
        case .say:
            try overlay(kind: "caption", rect: captionRect, text: text, durationMS: durationMS)
            try await speech.speak(text ?? "")
        case .cursor:
            try overlay(kind: primitive.rawValue, rect: resolvedTarget?.rect, text: nil, durationMS: durationMS ?? 1_200)
        case .highlight:
            try overlay(kind: primitive.rawValue, rect: resolvedTarget?.rect, text: text, durationMS: durationMS ?? 1_200)
        case .clear:
            DemoOverlayController.shared.clear(width: displayWidth, height: displayHeight)
        case .pause:
            try timeline.record(.pause, status: "paused")
            return statusJSON()
        case .resume:
            try timeline.record(.resume, status: "resumed")
            return statusJSON()
        case .wait:
            let milliseconds = try durationMS ?? { throw DemoRecorderError.message("wait requires duration_ms") }()
            try await Task.sleep(for: .milliseconds(max(0, milliseconds)))
            try timeline.record(.wait, durationMS: milliseconds)
            return statusJSON()
        case .startRecording, .stopRecording:
            break
        }
        try timeline.record(primitive, target: target, text: text, durationMS: durationMS)
        return statusJSON()
    }

    func stopSemanticRecording() async -> String {
        await stop()
        guard state == "completed" else { return statusJSON() }
        let events = timeline.finish(outputReference: outputReference)
        lastEvents = events
        if let outputURL {
            let eventsURL = outputURL.deletingPathExtension().appendingPathExtension("events.json")
            if let data = try? JSONEncoder().encode(events) {
                try? data.write(to: eventsURL, options: .atomic)
            }
        }
        return statusJSON()
    }

    func statusJSON() -> String {
        let baseJSON = CaptureTourStore.json([
            "state": state,
            "session_id": (sessionID ?? NSNull()) as Any,
            "elapsed_s": max(0, state == "recording" ? Date().timeIntervalSince(startedAt ?? Date()) : elapsed),
            "output_reference": outputReference ?? NSNull(),
            "display_width": displayWidth,
            "display_height": displayHeight,
            "timeline_active": timeline.isActive,
            "paused": timeline.isPaused,
            "error": lastError ?? NSNull(),
        ])
        var timelineValue: Any = NSNull()
        if timeline.isActive {
            timelineValue = (try? JSONEncoder().encode(timeline.events)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull()
        } else if !lastEvents.isEmpty {
            timelineValue = (try? JSONEncoder().encode(lastEvents)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull()
        }
        guard var object = (try? JSONSerialization.jsonObject(with: Data(baseJSON.utf8))) as? [String: Any] else { return baseJSON }
        object["timeline"] = timelineValue
        return CaptureTourStore.json(object)
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
        lastEvents = []
        lastError = nil
        timeline.start()
        timeline.finish(outputReference: nil)
    }

    private func resolved(for target: DemoTarget) throws -> DemoTarget {
        if target.rect != nil { return target }
        if let elementIndex = target.elementIndex {
            guard let element = NeoYAccessibilityController.shared.elementSnapshot(index: elementIndex, stateID: target.stateID) else {
                throw DemoRecorderError.message("Demo target is stale or element_index \(elementIndex) is unavailable; call computer.get_app_state again")
            }
            guard let bounds = element.bounds else {
                throw DemoRecorderError.message("Demo target element \(elementIndex) has no usable bounds")
            }
            return DemoTarget(
                rect: bounds.cgRect,
                stateID: target.stateID,
                elementIndex: elementIndex,
                path: target.path,
                label: target.label ?? element.title ?? element.value,
                role: target.role ?? element.role
            )
        }
        let frame = try NeoYAccessibilityController.shared.resolve(target).frame
        return DemoTarget(rect: frame, path: target.path, label: target.label, role: target.role)
    }

    private func overlay(kind: String, rect: CGRect?, text: String?, durationMS: Int?) throws {
        try DemoOverlayController.shared.update(
            kind: kind,
            rect: rect,
            text: text,
            durationMS: durationMS,
            width: displayWidth,
            height: displayHeight
        )
    }

    private var captionRect: CGRect {
        let width = Double(displayWidth)
        let height = Double(displayHeight)
        let captionHeight = max(80.0, height * 0.09)
        return CGRect(x: width * 0.12, y: height - captionHeight, width: width * 0.76, height: captionHeight)
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
        lastError = error.localizedDescription
        NSLog("NeoY demo recorder error: %@", error.localizedDescription)
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
        guard ["highlight", "spotlight", "annotate", "cursor", "caption", "clear"].contains(kind) else {
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
            case "annotate":
                context.setStrokeColor(NSColor.controlAccentColor.cgColor)
                context.setLineWidth(3)
                context.stroke(rect.insetBy(dx: 1, dy: 1))
                let text = (item.text ?? "") as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 20, weight: .medium),
                    .foregroundColor: NSColor.white,
                    .backgroundColor: NSColor.black.withAlphaComponent(0.75),
                ]
                let size = text.size(withAttributes: attributes)
                let labelRect = CGRect(x: rect.maxX + 12, y: rect.minY, width: size.width + 16, height: size.height + 12)
                (attributes[.backgroundColor] as? NSColor)?.setFill()
                context.fill(labelRect)
                text.draw(in: labelRect.insetBy(dx: 8, dy: 6), withAttributes: attributes)
            case "cursor":
                let circle = CGRect(x: rect.midX - 10, y: rect.midY - 10, width: 20, height: 20)
                context.setFillColor(NSColor.white.cgColor)
                context.fillEllipse(in: circle)
                context.setStrokeColor(NSColor.black.cgColor)
                context.setLineWidth(2)
                context.strokeEllipse(in: circle)
            default: break
            }
        }
    }
}

private final class DemoSpeechSpeaker: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Error>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) async throws {
        guard !text.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            self.synthesizer.stopSpeaking(at: .immediate)
            self.synthesizer.speak(AVSpeechUtterance(string: text))
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        MainActor.assumeIsolated {
            continuation?.resume()
            continuation = nil
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        MainActor.assumeIsolated {
            continuation?.resume()
            continuation = nil
        }
    }
}

enum DemoRecorderError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { value } else { nil } }
}

enum DemoRecorderTools {
    static func tools() -> [ToolDefinition] {
        let commands: [ToolDefinition] = [
            ToolDefinition(name: "demo.start_recording", description: "Reset the semantic timeline and start main-display H.264 recording.", parameters: schema([:])) { _ in
                await DemoRecorder.shared.startSemanticRecording()
            },
            ToolDefinition(name: "demo.step", description: "Mark a narrative step and semantic timeline boundary.", parameters: schema(["title": stringProp("Step title")], required: ["title"])) { args in
                try await DemoRecorderTools.run(.step, args: args)
            },
            ToolDefinition(name: "demo.spotlight", description: "Dim everything except the target.", parameters: targetSchema(text: true)) { args in
                try await DemoRecorderTools.run(.spotlight, args: args)
            },
            ToolDefinition(name: "demo.annotate", description: "Explanatory text beside a target.", parameters: targetSchema(text: true, requiredText: true)) { args in
                try await DemoRecorderTools.run(.annotate, args: args)
            },
            ToolDefinition(name: "demo.caption", description: "Show narration text.", parameters: schema(["text": stringProp("Caption text"), "duration_ms": integerProp()], required: ["text"])) { args in
                try await DemoRecorderTools.run(.caption, args: args)
            },
            ToolDefinition(name: "demo.say", description: "Speak narration and show its caption.", parameters: schema(["text": stringProp("Narration text")], required: ["text"])) { args in
                try await DemoRecorderTools.run(.say, args: args)
            },
            ToolDefinition(name: "demo.cursor", description: "Show a demo cursor at a target.", parameters: targetSchema()) { args in
                try await DemoRecorderTools.run(.cursor, args: args)
            },
            ToolDefinition(name: "demo.highlight", description: "Briefly emphasize a target.", parameters: targetSchema(text: true)) { args in
                try await DemoRecorderTools.run(.highlight, args: args)
            },
            ToolDefinition(name: "demo.clear", description: "Remove active demo overlays.", parameters: schema([:])) { args in
                try await DemoRecorderTools.run(.clear, args: args)
            },
            ToolDefinition(name: "demo.pause", description: "Pause demo timeline progression.", parameters: schema([:])) { args in
                try await DemoRecorderTools.run(.pause, args: args)
            },
            ToolDefinition(name: "demo.resume", description: "Resume demo timeline progression.", parameters: schema([:])) { args in
                try await DemoRecorderTools.run(.resume, args: args)
            },
            ToolDefinition(name: "demo.wait", description: "Hold for a deterministic duration.", parameters: schema(["ms": integerProp()], required: ["ms"])) { args in
                try await DemoRecorderTools.run(.wait, args: args)
            },
            ToolDefinition(name: "demo.stop_recording", description: "Stop capture and return the semantic timeline.", parameters: schema([:])) { _ in
                await DemoRecorder.shared.stopSemanticRecording()
            },
            ToolDefinition(name: "demo.start", description: "Compatibility alias for demo.start_recording.", parameters: schema([:])) { _ in
                await DemoRecorder.shared.startSemanticRecording()
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
                await DemoRecorder.shared.stopSemanticRecording()
            },
            ToolDefinition(name: "demo.cancel", description: "Cancel capture and remove its unfinished export.", parameters: schema([:])) { _ in
                await DemoRecorder.shared.cancel()
            },
        ]
        return [CommandTool.facade(
            name: "demo",
            description: "Record and annotate native product demos.",
            commands: commands,
            commandName: CommandTool.stripPrefix("demo.")
        )]
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

    private static func integerProp() -> JSONValue {
        .object(["type": .string("integer")])
    }

    private static func targetSchema(text: Bool = false, requiredText: Bool = false) -> JSONValue {
        var properties: [String: JSONValue] = [
            "target": .object([
                "type": .string("object"),
                "properties": .object([
                    "rect": .object(["type": .string("object")]),
                    "state_id": .object(["type": .string("string")]),
                    "element_index": .object(["type": .string("string")]),
                    "path": .object(["type": .string("string")]),
                    "label": .object(["type": .string("string")]),
                    "role": .object(["type": .string("string")]),
                ]),
            ]),
            "duration_ms": integerProp(),
        ]
        var required = ["target"]
        if text {
            properties["text"] = stringProp("Overlay text")
            if requiredText { required.append("text") }
        }
        return schema(properties, required: required)
    }

    private static func run(_ primitive: DemoPrimitive, args: JSONValue) async throws -> String {
        guard case .object(let object) = args else { throw DemoRecorderError.message("Invalid arguments") }
        var target: DemoTarget?
        if let raw = object["target"] {
            let data = try JSONEncoder().encode(raw)
            target = try JSONDecoder().decode(DemoTarget.self, from: data)
        }
        let text = object["text"].flatMap { if case .string(let value) = $0 { value } else { nil } }
        let duration = object["duration_ms"].flatMap { if case .int(let value) = $0 { value } else { nil } }
            ?? object["ms"].flatMap { if case .int(let value) = $0 { value } else { nil } }
        if primitive == .step, let text { target = DemoTarget(label: text) }
        return try await DemoRecorder.shared.perform(primitive, target: target, text: text, durationMS: duration)
    }
}
