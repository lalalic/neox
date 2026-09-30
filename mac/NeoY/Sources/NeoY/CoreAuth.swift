import Foundation
import Security

enum NeoYCoreAuth {
    private static let file = NeoYPaths.supportDirectory.appendingPathComponent("core-token")

    static func token() -> String {
        if let value = try? String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           value.count >= 32 {
            return value
        }
        try? FileManager.default.createDirectory(at: NeoYPaths.supportDirectory, withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let value: String
        if status == errSecSuccess {
            value = Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        } else {
            value = UUID().uuidString.replacingOccurrences(of: "-", with: "") +
                UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        try? (value + "\n").write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return value
    }

    static func url(_ base: String) -> String {
        guard var components = URLComponents(string: base) else { return base }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "token" }
        items.append(URLQueryItem(name: "token", value: token()))
        components.queryItems = items
        return components.string ?? base
    }
}
