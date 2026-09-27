import Foundation

/// Stable locations shared by the native NeoY services.
enum NeoYPaths {
    static let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NeoY", isDirectory: true)
    static let exports = supportDirectory.appendingPathComponent("exports", isDirectory: true)

    static func prepare() throws {
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
    }
}

/// The service seams intentionally stay small: later NeoX/media and demo work
/// can add implementations without coupling the menu-bar shell to transport or
/// platform details.
protocol NeoYPhoneClient: AnyObject {
    func status() async throws -> String
    func startDiscovery()
    func stopDiscovery()
}

protocol NeoYPhoneHandoffReceiver: AnyObject {
    func start() throws
    func stop()
}

protocol NeoYDemoRuntime: AnyObject {
    func status() async -> String
}

protocol NeoYAccessibilityService: AnyObject {
    func inspect(maxDepth: Int, maxNodes: Int) async throws -> String
}

protocol NeoYRecordingService: AnyObject {
    func start() async throws
    func stop() async throws -> URL
}

final class NeoYFileService {
    let root: URL

    var phoneExports: URL {
        root.appendingPathComponent("phone", isDirectory: true)
    }

    init(root: URL = NeoYPaths.exports) {
        self.root = root
    }

    func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func reference(for file: URL) -> String {
        "/files/\(file.lastPathComponent)"
    }

    func reference(for file: URL, in directory: URL) -> String {
        let root = directory.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        let relative = filePath.hasPrefix(root + "/") ? String(filePath.dropFirst(root.count + 1)) : file.lastPathComponent
        return "/files/\(relative)"
    }
}

private enum NeoYUnavailableError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        if case .unavailable(let message) = self { return message }
        return nil
    }
}

final class PendingNeoYDemoRuntime: NeoYDemoRuntime {
    func status() async -> String { "{\"state\":\"idle\"}" }
}

final class PendingNeoYAccessibilityService: NeoYAccessibilityService {
    func inspect(maxDepth: Int, maxNodes: Int) async throws -> String {
        throw NeoYUnavailableError.unavailable("NeoY accessibility service is not configured yet")
    }
}

@MainActor
final class NeoYDemoRecorderService: NeoYDemoRuntime {
    func status() async -> String {
        DemoRecorder.shared.statusJSON()
    }
}

final class PendingNeoYRecordingService: NeoYRecordingService {
    func start() async throws {
        throw NeoYUnavailableError.unavailable("NeoY recording service is provided by DemoRecorder")
    }

    func stop() async throws -> URL {
        throw NeoYUnavailableError.unavailable("NeoY recording service is provided by DemoRecorder")
    }
}

@MainActor
final class NeoYServiceRegistry {
    static let shared = NeoYServiceRegistry()

    let files: NeoYFileService
    let phone: NeoYPhoneClient
    let handoff: NeoYPhoneHandoffReceiver
    let demo: NeoYDemoRuntime
    let accessibility: NeoYAccessibilityService
    let recording: NeoYRecordingService

    init(
        files: NeoYFileService = NeoYFileService(),
        targetStore: NeoXPhoneTargetStore = NeoXPhoneTargetStore(),
        demo: NeoYDemoRuntime = NeoYDemoRecorderService(),
        accessibility: NeoYAccessibilityService = NeoYAccessibilityController.shared,
        recording: NeoYRecordingService = PendingNeoYRecordingService()
    ) {
        self.files = files
        self.phone = NeoXPhoneClient(targetStore: targetStore, files: files)
        self.handoff = NativeNeoYPhoneHandoffReceiver(targetStore: targetStore)
        self.demo = demo
        self.accessibility = accessibility
        self.recording = recording
    }
}
