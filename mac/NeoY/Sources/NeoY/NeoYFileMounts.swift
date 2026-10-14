import Foundation

/// Explicit read-only roots exposed under /files/<name>/... .
/// Only directories deliberately listed in file-mounts.json become visible.
struct NeoYFileMounts {
    static let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/NeoY/file-mounts.json")

    static func load() -> [String: URL] {
        guard let data = try? Data(contentsOf: configURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        var roots: [String: URL] = [:]
        for (name, path) in raw {
            guard name != "_neoy", name.range(of: "^[a-zA-Z0-9_-]{1,64}$", options: .regularExpression) != nil,
                  path.hasPrefix("/") else { continue }
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                roots[name] = url
            }
        }
        return roots
    }
}
