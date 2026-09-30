import AVFoundation
import AppKit
import SwiftUI

@main
struct NeoYApp: App {
    @NSApplicationDelegateAdaptor(NeoYAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("NeoY", systemImage: "video") {
            Button("Open Current Tour") { appDelegate.showTourWindow() }
            Button("Setup…") { appDelegate.showSetupWindow() }
            Divider()
            Button("Quit NeoY") { NSApp.terminate(nil) }
        }
    }
}

@MainActor
final class NeoYAppDelegate: NSObject, NSApplicationDelegate {
    private let services = NeoYServiceRegistry.shared
    private let store = CaptureTourStore.shared
    private let runner = CaptureRunner()
    private var server: MCPServer?
    private var window: NSWindow?
    private var setupWindow: NSWindow?
    private var runtimeControl: NeoYRuntimeControl?
    private let coreExec = NeoYExecService()
    private let coreFiles = NeoYCoreFileService()
    private let coreCodex = NeoYCodexThreadService()
    private let coreNodes = NeoYNodeService()
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        startServer()
        startNativePhoneServices()
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
        observers.append(NotificationCenter.default.addObserver(
            forName: .neoYDeploymentSettingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.restartPrimaryMCPServer() }
        })
    }

    func applicationWillTerminate(_ notification: Notification) {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        services.phone.stopDiscovery()
        services.handoff.stop()
        runtimeControl?.stop()
    }

    func showTourWindow() {
        if window == nil {
            let root = CaptureTourView(runner: runner).environmentObject(store)
            let controller = NSHostingController(rootView: root)
            let value = NSWindow(contentViewController: controller)
            value.title = "NeoY Capture Tour"
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

    func showSetupWindow() {
        if setupWindow == nil {
            let controller = NSHostingController(rootView: NeoYSetupView())
            let value = NSWindow(contentViewController: controller)
            value.title = "NeoY Setup"
            value.styleMask = [.titled, .closable, .miniaturizable]
            value.isReleasedWhenClosed = false
            value.center()
            setupWindow = value
        }
        setupWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func restartPrimaryMCPServer() {
        runtimeControl?.stop()
        server?.stop()
        runtimeControl = nil
        server = nil
        startServer()
    }

    private func startServer() {
        let deployment = NeoYDeploymentSettingsStore.load()
        let value = MCPServer(name: "NeoY", version: NeoYCoreRuntime.version, port: deployment.mcpPort,
                              bonjourName: "NeoY")
        value.setPrivilegedAccessToken(NeoYCoreAuth.token())
        value.setRemoteAllowedFeatures(deployment.enabledRemoteFeatures)

        let configuration = (try? NeoYFileControlPlaneStore(directory: NeoYPaths.supportDirectory)
            .loadOrCreate().document.configuration) ?? NeoYControlPlaneConfiguration()
        let phone = services.phone as! NeoXPhoneClient
        let runtimeControl = NeoYRuntimeControl(server: value, phone: phone)
        let setup = NeoYSetupService(
            makeStatus: { [weak value] in
                await MainActor.run { NeoYAppDelegate.runtimeStatus(server: value) }
            },
            runtime: runtimeControl,
            onDeploymentChanged: { [weak self] in
                await MainActor.run { self?.restartPrimaryMCPServer() }
                await Self.controlTunnelRuntime(action: "tunnel-restart")
            },
            onCapabilitiesChanged: { [weak self] updated in
                await MainActor.run { self?.restartPrimaryMCPServer() }
                if updated.capabilities.isEnabled(.publicTunnel) {
                    await Self.controlTunnelRuntime(action: "tunnel-restart")
                } else {
                    await Self.controlTunnelRuntime(action: "tunnel-stop")
                }
            }
        )
        self.runtimeControl = runtimeControl
        Task {
            await runtimeControl.reconcile(await setup.currentConfiguration())
        }

        NeoYCoreRuntime.register(
            on: value,
            setup: setup,
            exec: coreExec,
            files: coreFiles,
            codex: coreCodex,
            node: coreNodes
        )

        if configuration.capabilities.isEnabled(.captureTour) {
            value.register(tools: CaptureTourTools.tools())
        }
        if configuration.capabilities.isEnabled(.demoRecording) {
            value.register(tools: DemoRecorderTools.tools())
        }
        if configuration.capabilities.isEnabled(.accessibilityComputer) {
            value.register(tools: AccessibilityTools.tools())
        }
        if configuration.capabilities.isEnabled(.phoneIntegration) {
            value.register(tools: NeoXPhoneTools.tools(client: phone,
                                                       handoff: services.handoff as! NativeNeoYPhoneHandoffReceiver))
        }

        (services.handoff as? NativeNeoYPhoneHandoffReceiver)?.registerRoutes(on: value)
        try? services.files.prepare()
        value.setStaticFileRoot(services.files.root)
        try? value.start()
        server = value
    }

    @MainActor
    private static func runtimeStatus(server: MCPServer?) -> NeoYRuntimeStatus {
        let services = NeoYServiceRegistry.shared
        let serverIsRunning = server?.isRunning == true
        let handoff = services.handoff as? NativeNeoYPhoneHandoffReceiver
        let handoffError: String?
        if let handoff, handoff.isRunning {
            handoffError = nil
        } else if handoff == nil {
            handoffError = "handoff service is unavailable"
        } else {
            handoffError = "handoff listener is not running"
        }

        return NeoYRuntimeStatus(
            state: serverIsRunning && handoffError == nil ? .ready : .degraded,
            version: NeoYCoreRuntime.version,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.neox.neoy",
            startupMode: FileManager.default.fileExists(
                atPath: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/NeoY/neoy-pm2.config.cjs").path
            ) ? "pm2" : "launch-agent-keepalive",
            mcp: NeoYRuntimeEndpoint(
                name: "NeoY",
                url: NeoYDeploymentSettingsStore.load().localMCPURL,
                isRunning: serverIsRunning,
                error: serverIsRunning ? nil : "MCP listener is not running"
            ),
            neoXPairing: (services.phone as? NeoXPhoneClient)?.pairingSelection ?? .unavailable,
            handoff: NeoYRuntimeEndpoint(
                name: "_neoy._tcp",
                url: "http://127.0.0.1:\(NeoYDeploymentSettingsStore.load().mcpPort)/agent",
                isRunning: services.handoff.isRunning,
                error: handoffError
            ),
            capabilities: Self.runtimeCapabilities()
        )
    }

    nonisolated private static func controlTunnelRuntime(action: String) async {
        guard let script = Bundle.main.url(forResource: "runtime-control", withExtension: "sh") else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [script.path, action]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private static func runtimeCapabilities() -> [String] {
        let config = (try? NeoYFileControlPlaneStore(directory: NeoYPaths.supportDirectory)
            .loadOrCreate().document.configuration) ?? NeoYControlPlaneConfiguration()
        var result = ["core_setup", "core_exec", "core_files", "core_codex_threads", "core_nodes",
                      "permissions", "startup_supervisor", "mcp_federation", "neox_events"]
        if config.capabilities.isEnabled(.captureTour) { result.append("capture_tour") }
        if config.capabilities.isEnabled(.demoRecording) { result.append("demo") }
        if config.capabilities.isEnabled(.accessibilityComputer) { result.append("accessibility") }
        if config.capabilities.isEnabled(.phoneIntegration) { result.append("phone_media") }
        if config.capabilities.isEnabled(.publicTunnel) { result.append("public_tunnel") }
        return result
    }

    private func startNativePhoneServices() {
        services.phone.startDiscovery()
        do { try services.handoff.start() }
        catch { NSLog("NeoY handoff Bonjour registration failed: %@", error.localizedDescription) }
    }
}

extension Notification.Name {
    static let captureTourStarted = Notification.Name("NeoY.captureTourStarted")
    static let captureTourCompleted = Notification.Name("NeoY.captureTourCompleted")
    static let captureTourCancelled = Notification.Name("NeoY.captureTourCancelled")
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
        let exports = NeoYPaths.exports
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
                Text("NeoY Capture Tour").font(.largeTitle.bold())
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
