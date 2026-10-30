import Foundation
import Darwin
import os

// Standalone root-owned, signed executable. Never add a generic command runner,
// filesystem mutation, shell interpolation, user-supplied program, or path.
enum PrivilegedAction: String, CaseIterable {
    case dnsFlush = "dns.flush"
    case vpnServerStatus = "vpn.server.status"
    case vpnRoutingStatus = "vpn.routing.status"
    case vpnServerRestart = "vpn.server.restart"
    case vpnRoutingRestart = "vpn.routing.restart"

    var commands: [(String, [String])] {
        switch self {
        case .dnsFlush:
            return [
                ("/usr/bin/dscacheutil", ["-flushcache"]),
                ("/usr/bin/killall", ["-HUP", "mDNSResponder"])
            ]
        case .vpnServerStatus:
            return [("/bin/launchctl", ["print", "system/io.macikev2.server"])]
        case .vpnRoutingStatus:
            return [("/bin/launchctl", ["print", "system/io.macikev2.routing"])]
        case .vpnServerRestart:
            return [("/bin/launchctl", ["kickstart", "-k", "system/io.macikev2.server"])]
        case .vpnRoutingRestart:
            return [("/bin/launchctl", ["kickstart", "-k", "system/io.macikev2.routing"])]
        }
    }
}

func fail(_ message: String, code: Int32 = 64) -> Never {
    fputs("Neo privileged helper: \(message)\n", stderr)
    exit(code)
}

func logAttempt(action: String, status: String) {
    // macOS Unified Logging is not an agent-writable plaintext audit file.
    let user = ProcessInfo.processInfo.environment["SUDO_USER"] ?? "root"
    let logger = Logger(subsystem: "com.neox.neoy", category: "privileged-helper")
    logger.notice("user=\(user, privacy: .public) action=\(action, privacy: .public) result=\(status, privacy: .public)")
}

let args = Array(CommandLine.arguments.dropFirst())
if args == ["version"] {
    print("1") // Bump whenever the approved operations or policy changes.
    exit(0)
}
if args == ["list"] {
    PrivilegedAction.allCases.forEach { print($0.rawValue) }
    exit(0)
}

// Testing/diagnostics have no privileged side effects.
if args.count == 2 && args[0] == "check" {
    guard let action = PrivilegedAction(rawValue: args[1]) else { fail("DENIED: unknown action") }
    for (path, arguments) in action.commands {
        print(([path] + arguments).joined(separator: " "))
    }
    exit(0)
}

guard args.count == 2, args[0] == "run",
      let action = PrivilegedAction(rawValue: args[1]) else {
    logAttempt(action: "invalid", status: "denied")
    fail("DENIED: expected run <approved-action>, list or check <approved-action>")
}
guard getuid() == 0, geteuid() == 0 else {
    logAttempt(action: action.rawValue, status: "not-root")
    fail("must be invoked through the installed sudo policy", code: 77)
}

// A completely fixed argv per action. No user input reaches subprocess argv.
// Direct Process execution bypasses shell parsing and aliases.
for (path, arguments) in action.commands {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: path)
    child.arguments = arguments
    child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/var/root",
                         "LANG": "C", "LC_ALL": "C"]
    child.standardInput = FileHandle.nullDevice
    do {
        try child.run()
        child.waitUntilExit()
    } catch {
        logAttempt(action: action.rawValue, status: "spawn-error")
        fail("execution failed for approved action", code: 70)
    }
    guard child.terminationReason == .exit, child.terminationStatus == 0 else {
        logAttempt(action: action.rawValue, status: "failed-\(child.terminationStatus)")
        fail("approved action failed with exit \(child.terminationStatus)", code: 1)
    }
}
logAttempt(action: action.rawValue, status: "success")
print("ok: \(action.rawValue)")
