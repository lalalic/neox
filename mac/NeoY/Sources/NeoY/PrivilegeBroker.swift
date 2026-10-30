import Foundation

/// Non-interactive client of the root-owned, narrowly allowlisted helper.
/// Installing or changing the helper requires a separate macOS admin approval.
enum NeoYPrivilegeBroker {
    static let helperPath = "/Library/PrivilegedHelperTools/com.neox.neoy.helper"
    static let actions: Set<String> = [
        "dns.flush", "vpn.server.status", "vpn.routing.status",
        "vpn.server.restart", "vpn.routing.restart"
    ]

    static func status() -> [String: String] {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: helperPath),
              let metadata = try? fm.attributesOfItem(atPath: helperPath),
              let owner = metadata[.ownerAccountID] as? NSNumber, owner.intValue == 0,
              let mode = metadata[.posixPermissions] as? NSNumber,
              mode.intValue & 0o022 == 0 else {
            return ["state": "not_installed", "hint": "Install the signed helper once with macOS administrator approval."]
        }
        do {
            let result = try invoke(["-n", "-k", helperPath, "check", "dns.flush"])
            return ["state": result.code == 0 ? "ready" : "authorization_required",
                    "hint": result.code == 0 ? "Allowed privileged actions are available without a password." :
                        "Helper is present, but passwordless sudo policy is not active."]
        } catch {
            return ["state": "authorization_required", "hint": error.localizedDescription]
        }
    }

    static func run(_ action: String) throws -> [String: String] {
        guard actions.contains(action) else {
            throw NSError(domain: "NeoYPrivilege", code: 64,
                userInfo: [NSLocalizedDescriptionKey: "Denied: operation is not allowlisted."])
        }
        let result = try invoke(["-n", helperPath, "run", action])
        guard result.code == 0 else {
            throw NSError(domain: "NeoYPrivilege", code: Int(result.code),
                userInfo: [NSLocalizedDescriptionKey: "Privileged action failed (exit \(result.code)): \(result.output.prefix(800))"])
        }
        return ["state": "completed", "action": action, "result": String(result.output.prefix(800))]
    }

    private static func invoke(_ arguments: [String]) throws -> (code: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
