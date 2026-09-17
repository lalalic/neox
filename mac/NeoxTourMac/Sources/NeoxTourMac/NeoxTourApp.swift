import AVFoundation
import AppKit
import SwiftUI

@main
struct NeoxTourApp: App {
    @NSApplicationDelegateAdaptor(NeoxTourAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Neox Tour", systemImage: "video") {
            Button("Open Current Tour") { appDelegate.showTourWindow() }
            Divider()
            Button("Quit Neox Tour") { NSApp.terminate(nil) }
        }
    }
}

@MainActor
final class NeoxTourAppDelegate: NSObject, NSApplicationDelegate {
    private let store = CaptureTourStore.shared
    private let runner = CaptureRunner()
    private var server: MCPServer?
    private var window: NSWindow?
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        startServer()
        observers.append(NotificationCenter.default.addObserver(
            forName: .captureTourStarted, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.showTourWindow() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .captureTourCompleted, object: nil, queue: .main
        ) { [weak self] note in
            let sessionID = note.userInfo?["session_id"] as? String
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                guard let self,
                      self.store.session?.sessionID == sessionID,
                      self.store.session?.state == "completed" else { return }
                self.window?.orderOut(nil)
                self.runner.releaseCapture()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .captureTourCancelled, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.window?.orderOut(nil)
                self?.runner.releaseCapture()
            }
        })
    }

    func applicationWillTerminate(_ notification: Notification) {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func showTourWindow() {
        if window == nil {
            let root = CaptureTourView(runner: runner).environmentObject(store)
            let controller = NSHostingController(rootView: root)
            let value = NSWindow(contentViewController: controller)
            value.title = "Neox Tour"
            value.setContentSize(NSSize(width: 860, height: 700))
            value.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            value.isReleasedWhenClosed = false
            value.center()
            window = value
        }
        runner.configure()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startServer() {
        let value = MCPServer(name: "neox-tour-mac", version: "1.0.0", port: 9224,
                              bonjourName: "neox-tour-mac")
        value.register(tools: CaptureTourTools.tools())
        let exports = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NeoxTourMac/exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        value.setStaticFileRoot(exports)
        try? value.start()
        server = value
    }
}

extension Notification.Name {
    static let captureTourStarted = Notification.Name("NeoxTour.captureTourStarted")
    static let captureTourCompleted = Notification.Name("NeoxTour.captureTourCompleted")
    static let captureTourCancelled = Notification.Name("NeoxTour.captureTourCancelled")
}

@MainActor
final class CaptureRunner: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    let movieOutput = AVCaptureMovieFileOutput()
    @Published private(set) var isConfigured = false
    @Published private(set) var isRecording = false
    @Published private(set) var hasTake = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var previewError: String?
    private var recordingStartedAt: Date?
    private var completedDurationS: Double = 0
    private var temporaryURL: URL?

    override init() {
        super.init()
    }

    func configure() {
        guard !isConfigured else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    if granted { self?.configureSession() } else { self?.previewError = "Camera access was denied." }
                }
            }
        default: previewError = "Camera access is unavailable. Enable it in System Settings."
        }
    }

    private func configureSession() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor in self?.configureSession() }
            }
            return
        }
        session.beginConfiguration()
        session.sessionPreset = .high
        defer { session.commitConfiguration() }
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input), session.canAddOutput(movieOutput) else {
            previewError = "No usable camera was found."
            return
        }
        session.addInput(input)
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           let microphone = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: microphone),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }
        session.addOutput(movieOutput)
        isConfigured = true
        DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
    }

    func releaseCapture() {
        if isRecording { movieOutput.stopRecording() }
        if session.isRunning { session.stopRunning() }
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        isConfigured = false
        previewError = nil
        retake()
    }

    func startRecording() {
        guard isConfigured, !isRecording else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("neox-tour-\(UUID().uuidString).mov")
        try? FileManager.default.removeItem(at: url)
        temporaryURL = url
        recordingStartedAt = Date()
        completedDurationS = 0
        elapsed = 0
        hasTake = false
        isRecording = true
        movieOutput.startRecording(to: url, recordingDelegate: self)
        Task { @MainActor [weak self] in
            while let self, self.isRecording {
                self.elapsed = Date().timeIntervalSince(self.recordingStartedAt ?? Date())
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        movieOutput.stopRecording()
    }

    func retake() {
        guard !isRecording else { return }
        if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
        temporaryURL = nil
        recordingStartedAt = nil
        completedDurationS = 0
        elapsed = 0
        hasTake = false
    }

    func acceptCurrent() {
        guard let url = temporaryURL, let session = CaptureTourStore.shared.session,
              session.currentIndex < session.manifest.shots.count else { return }
        let shot = session.manifest.shots[session.currentIndex]
        let exports = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NeoxTourMac/exports", isDirectory: true)
        let safeShotID = shot.id.replacingOccurrences(of: "/", with: "_")
        let takeNumber = session.results.filter { $0.shotID == shot.id }.count + 1
        let name = "\(session.sessionID)-\(safeShotID)-\(takeNumber).mov"
        let destination = exports.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: destination)
            appendResult(status: "accepted", duration: completedDurationS, reference: "/files/\(name)")
        } catch { previewError = "Could not save take: \(error.localizedDescription)" }
    }

    func skipCurrent() {
        guard !isRecording else { return }
        if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
        appendResult(status: "skipped", duration: 0, reference: nil)
    }

    private func appendResult(status: String, duration: Double, reference: String?) {
        guard var value = CaptureTourStore.shared.session,
              value.currentIndex < value.manifest.shots.count else { return }
        let shotID = value.manifest.shots[value.currentIndex].id
        value.results.append(CaptureResult(shotID: shotID, status: status, takeCount: value.results.filter { $0.shotID == shotID }.count + 1,
                                           actualDurationS: duration, createdAt: Date(), mediaReference: reference, qualityWarnings: []))
        value.currentIndex += 1
        value.state = value.currentIndex >= value.manifest.shots.count ? "completed" : "ready"
        CaptureTourStore.shared.update(value)
        if value.state == "completed" {
            NotificationCenter.default.post(name: .captureTourCompleted, object: nil, userInfo: ["session_id": value.sessionID])
        }
        temporaryURL = nil
        recordingStartedAt = nil
        completedDurationS = 0
        elapsed = 0
        hasTake = false
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        let recordedDuration = CMTimeGetSeconds(output.recordedDuration)
        Task { @MainActor in
            self.isRecording = false
            self.completedDurationS = recordedDuration.isFinite ? max(0, recordedDuration) : 0
            self.elapsed = self.completedDurationS
            if let error, (error as NSError).code != AVError.Code.maximumDurationReached.rawValue {
                self.previewError = "Recording failed: \(error.localizedDescription)"
                self.hasTake = false
            } else {
                self.hasTake = true
            }
        }
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.wantsLayer = true
        view.layer = layer
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.layer?.frame = nsView.bounds
    }
}

struct CaptureTourView: View {
    @EnvironmentObject private var store: CaptureTourStore
    @ObservedObject var runner: CaptureRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Neox Tour").font(.largeTitle.bold())
                Spacer()
                Circle().fill(runner.isConfigured ? .green : .orange).frame(width: 10, height: 10)
                Text(runner.isConfigured ? "Camera ready" : "Waiting for camera")
            }
            if let session = store.session {
                Text(session.manifest.title).font(.title2)
                if session.state == "completed" {
                    Label("Tour complete", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else if session.currentIndex < session.manifest.shots.count {
                    let shot = session.manifest.shots[session.currentIndex]
                    Text("Shot \(session.currentIndex + 1) of \(session.manifest.shots.count): \(shot.title)").font(.headline)
                    if let instruction = shot.instruction { Text(instruction).foregroundStyle(.secondary) }
                    CameraPreview(session: runner.session).clipShape(RoundedRectangle(cornerRadius: 12)).frame(minHeight: 360)
                    if let target = shot.targetDurationS {
                        ProgressView(value: min(runner.elapsed / max(target, 0.1), 1))
                            .tint(runner.elapsed >= target ? .green : .accentColor)
                        HStack {
                            Text("\(runner.elapsed, specifier: "%.1f") / \(target, specifier: "%.0f")s")
                                .font(.caption.monospacedDigit())
                            Spacer()
                            if runner.isRecording && runner.elapsed >= target {
                                Text("Target reached — keep recording or stop")
                                    .font(.caption.bold())
                                    .foregroundStyle(.green)
                            } else if runner.isRecording {
                                Text("Recording")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("\(runner.elapsed, specifier: "%.1f")s")
                            .font(.caption.monospacedDigit())
                    }
                    HStack {
                        Button(runner.isRecording ? "Stop recording" : "Record take") {
                            runner.isRecording ? runner.stopRecording() : runner.startRecording()
                        }.keyboardShortcut(.return).disabled(!runner.isConfigured)
                        Button("Retake") { runner.retake() }.disabled(runner.isRecording || runner.isConfigured == false)
                        Button("Accept") { runner.acceptCurrent() }.disabled(runner.isRecording || !runner.hasTake)
                        Button("Skip") { runner.skipCurrent() }.disabled(runner.isRecording)
                    }
                }
                Text("Accepted \(session.results.filter { $0.status == "accepted" }.count)  ·  Skipped \(session.results.filter { $0.status == "skipped" }.count)").foregroundStyle(.secondary)
            } else {
                Text("Start a tour with tour.start from your MCP client.").foregroundStyle(.secondary)
                Spacer()
            }
            if let error = runner.previewError { Text(error).foregroundStyle(.red) }
        }
        .padding(24)
    }
}
