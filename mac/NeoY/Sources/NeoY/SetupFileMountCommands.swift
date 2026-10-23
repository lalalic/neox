import Foundation

enum NeoYSetupFiles {
    static func execute(_ command: NeoYSetupCommand) throws -> String {
        let url = NeoYFileMounts.configURL
        var mounts: [String: String] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            mounts = try JSONDecoder().decode([String: String].self, from: data)
        }
        func validateName(_ name: String) throws {
            guard name != "_neoy", name.range(of: "^[a-zA-Z0-9_-]{1,64}$", options: .regularExpression) != nil else {
                throw NeoYSetupError.invalidValue("invalid or reserved mount name")
            }
        }
        func save() throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(mounts)
            try data.write(to: url, options: [.atomic])
        }
        func json(_ object: [String: String]) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }
        switch command {
        case .filesList: return try json(mounts)
        case .filesMount(let name, let path):
            try validateName(name)
            guard path.hasPrefix("/") else { throw NeoYSetupError.invalidValue("mount path must be absolute") }
            let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
                throw NeoYSetupError.invalidValue("mount target must be an existing directory")
            }
            mounts[name] = root.path
            try save()
            return try json(["name": name, "path": root.path, "status": "mounted", "visibility": "public"])
        case .filesUnmount(let name):
            try validateName(name)
            mounts.removeValue(forKey: name)
            try save()
            return try json(["name": name, "status": "unmounted"])
        case .filesURL(let path):
            let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            let origin: String
            let deployment = NeoYDeploymentSettingsStore.load()
            guard deployment.tunnelMode == .named, !deployment.publicHostname.isEmpty else {
                throw NeoYSetupError.invalidValue("a named Neo public HTTPS hostname is required")
            }
            origin = "https://" + deployment.publicHostname
            for (name, rootPath) in mounts.sorted(by: { $0.key < $1.key }) {
                try validateName(name)
                let root = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath().path
                guard file.hasPrefix(root + "/") else { continue }
                let relative = String(file.dropFirst(root.count + 1)).split(separator: "/").map(String.init)
                guard !relative.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.hasPrefix(".") }) else { continue }
                let encoded = relative.map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }.joined(separator: "/")
                return try json(["url": origin + "/files/" + name + "/" + encoded, "path": file])
            }
            throw NeoYSetupError.invalidValue("file is not inside a public mounted root")
        default: throw NeoYSetupError.unknownCommand("files")
        }
    }
}
