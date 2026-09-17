import AVFoundation
import AppKit
import SwiftUI

@main
struct NeoxTourApp: App {
    @StateObject private var store = CaptureTourStore.shared
    @StateObject private var runner = CaptureRunner()
    private let server: MCPServer

    init() {
        let server = MCPServer(name: "neox-tour-mac", version: "1.0.0", port: 9224,
                               bonjourName: "neox-tour-mac")
        server.register(tools: CaptureTourTools.tools())
        let exports = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NeoxTourMac/exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        server.setStaticFileRoot(exports)
        try? server.start()
        self.server = server
    }

    var body: some Scene {
        WindowGroup("Neox Tour") {
            CaptureTourView(runner: runner)
                .environmentObject(store)
                .frame(minWidth: 780, minHeight: 620)
        }
        .commands { CommandGroup(replacing: .appInfo) { } }
    }
}

@MainActor
final class CaptureRunner: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    let movieOutput = AVCaptureMovieFileOutput()
    @Published private(set) var isConfigured = false
    @Published private(set) var isRecording = false
    @Published private(set) var hasTake = false
    @Published private(set) var previewError: String?
    private var recordingStartedAt: Date?
    private var temporaryURL: URL?

    override init() {
        super.init()
        configure()
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

    func startRecording() {
        guard isConfigured, !isRecording else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("neox-tour-\(UUID().uuidString).mov")
        try? FileManager.default.removeItem(at: url)
        temporaryURL = url
        recordingStartedAt = Date()
        hasTake = false
        isRecording = true
        movieOutput.startRecording(to: url, recordingDelegate: self)
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
            let duration = Date().timeIntervalSince(recordingStartedAt ?? Date())
            appendResult(status: "accepted", duration: duration, reference: "/files/\(name)")
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
        temporaryURL = nil
        recordingStartedAt = nil
        hasTake = false
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        Task { @MainActor in
            self.isRecording = false
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
