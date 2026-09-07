import Foundation
import Network
import UIKit

/// MCP tool reporting device facts an agent needs before pulling media
/// (storage free space for export preflight, battery/power state, etc.).
public enum DeviceToolProvider {

    public static func tools() -> [ToolDefinition] {
        [
            ToolDefinition(
                name: "device_info",
                description: """
                Report device facts: model, iOS/app version, battery level+state, \
                free/total storage (bytes), network type. Useful to check storage \
                before exporting large videos.
                """,
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                ]),
                handler: { _ in
                    await info()
                }
            ),
        ]
    }

    private static func info() async -> String {
        // UIDevice is MainActor-isolated — collect device facts there first.
        // Build the JSON inside the actor to keep non-Sendable values in one place.
        let json = await MainActor.run { () -> String in
            let device = UIDevice.current
            device.isBatteryMonitoringEnabled = true
            let batteryState: String = switch device.batteryState {
            case .charging: "charging"
            case .full: "full"
            case .unplugged: "unplugged"
            default: "unknown"
            }
            var item: [String: Any] = [
                "model": machineModel(),
                "ios_version": device.systemVersion,
                "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
                "battery_level": device.batteryLevel >= 0 ? device.batteryLevel : -1,
                "battery_state": batteryState,
                "low_power_mode": ProcessInfo.processInfo.isLowPowerModeEnabled,
            ]

            let storage = try? URL(fileURLWithPath: "/", isDirectory: true)
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
            item["storage_free_bytes"] = storage?.volumeAvailableCapacityForImportantUsage ?? -1
            item["storage_total_bytes"] = storage?.volumeTotalCapacity ?? -1

            guard let data = try? JSONSerialization.data(withJSONObject: item, options: [.sortedKeys]) else {
                return "{\"error\":\"serialization failed\"}"
            }
            return String(data: data, encoding: .utf8) ?? "{\"error\":\"encoding failed\"}"
        }

        let network = await networkType()
        // Inject network into the JSON: parse, add, re-serialize.
        guard var item = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
            return json
        }
        item["network"] = network
        guard let data = try? JSONSerialization.data(withJSONObject: item, options: [.sortedKeys]) else {
            return json
        }
        return String(data: data, encoding: .utf8) ?? json
    }

    private static func networkType() async -> String {
        await withCheckedContinuation { cont in
            let once = Once()
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                once.run {
                    monitor.cancel()
                    guard path.status == .satisfied else { cont.resume(returning: "offline"); return }
                    let type: String
                    if path.usesInterfaceType(.wifi) { type = "wifi" }
                    else if path.usesInterfaceType(.cellular) { type = "cellular" }
                    else if path.usesInterfaceType(.wiredEthernet) { type = "wired" }
                    else { type = "unknown" }
                    cont.resume(returning: type)
                }
            }
            monitor.start(queue: DispatchQueue.global(qos: .utility))
        }
    }

    private static func machineModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { buffer in
            let data = Data(buffer.prefix(while: { $0 != 0 }))
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Resumes a continuation at most once (NWPathMonitor may fire multiple updates).
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(_ body: () -> Void) {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            done = true
            body()
        }
    }
}
