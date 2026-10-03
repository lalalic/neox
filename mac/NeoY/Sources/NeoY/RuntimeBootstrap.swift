import Foundation

enum NeoYRuntimeBootstrap {
    static func prepare() async -> Bool {
        guard let script = Bundle.main.url(forResource: "bootstrap-runtime", withExtension: "sh") else {
            fputs("NeoY bootstrap script is missing\n", stderr)
            return false
        }
        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [script.path]
            process.environment = NeoYProcessEnvironment.childEnvironment()
            let logURL = NeoYPaths.supportDirectory.appendingPathComponent("bootstrap.log")
            try? FileManager.default.createDirectory(at: NeoYPaths.supportDirectory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: logURL) else { return false }
            defer { try? handle.close() }
            process.standardOutput = handle
            process.standardError = handle
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                let line = "NeoY bootstrap failed to launch: \(error.localizedDescription)\n"
                if let data = line.data(using: .utf8) { try? handle.write(contentsOf: data) }
                return false
            }
        }.value
    }
}
