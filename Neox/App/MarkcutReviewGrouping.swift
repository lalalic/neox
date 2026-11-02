import Foundation

struct MarkcutReviewGroup: Identifiable {
    struct Revision: Identifiable {
        let value: [String: Any]
        let reviewSessionID: String
        let title: String
        var id: String { reviewSessionID }
    }
    let id: String
    let title: String
    let jobID: String?
    let sessions: [Revision]
    let pendingCount: Int
}

enum MarkcutReviewGrouping {
    #if DEBUG
    static var uiFixture: [[String: Any]] { [
        ["id":"fixture-current", "label":"video-a-v2", "status":"ready", "createdAt":"2026-11-02T12:00:00Z",
         "updatedAt":"2026-11-02T12:00:00Z",
         "relayCorrelations":[["jobId":"review-fixture-job"]]],
        ["id":"fixture-old", "label":"video-a-v1", "status":"superseded", "createdAt":"2026-11-02T11:00:00Z",
         "updatedAt":"2026-11-02T11:00:00Z",
         "relayCorrelations":[["jobId":"review-fixture-job"]]]
    ] }
    #endif

    static func groups(from sessions: [[String: Any]]) -> [MarkcutReviewGroup] {
        var buckets: [String: [[String: Any]]] = [:]
        for (index, session) in sessions.enumerated() {
            let id = session["id"] as? String ?? "session-\(index)"
            let relayRows = session["relayCorrelations"] as? [[String: Any]] ?? []
            let jobIDs = Array(Set(relayRows.compactMap { $0["jobId"] as? String })).sorted()
            if !jobIDs.isEmpty {
                for jobID in jobIDs { buckets["job:\(jobID)", default: []].append(session) }
                continue
            }
            let identity = sourceIdentity(session)
            let key = identity.key ?? "session:\(id)"
            buckets[key, default: []].append(session)
        }
        return buckets.map { key, values in
            let ordered = values.sorted { timestamp($0) > timestamp($1) }
            let jobID = key.hasPrefix("job:") ? String(key.dropFirst("job:".count)) : nil
            let identity = sourceIdentity(ordered[0])
            let title: String
            if let jobID { title = "Job #\(jobDisplay(jobID))" }
            else { title = identity.title ?? "Markcut video" }
            let revisions: [MarkcutReviewGroup.Revision] = ordered.map { session in
                MarkcutReviewGroup.Revision(value: session,
                    reviewSessionID: session["id"] as? String ?? UUID().uuidString,
                    title: revisionTitle(session))
            }
            let pending = ordered.filter { isPending($0) }.count
            return MarkcutReviewGroup(id: key, title: title, jobID: jobID, sessions: revisions, pendingCount: pending)
        }.sorted {
            timestamp($0.sessions.first?.value ?? [:]) > timestamp($1.sessions.first?.value ?? [:])
        }
    }

    static func statusText(_ item: [String: Any]) -> String {
        if let decision = item["decision"] as? [String: Any], let value = decision["decision"] as? String {
            return value == "approved" ? "Approved" : "Changes requested"
        }
        let status = item["status"] as? String ?? "pending"
        switch status {
        case "ready": return "Ready for review"
        case "compiling": return "Compiling"
        case "superseded": return "Historical revision"
        case "failed": return "Preview failed"
        case "decided": return "Decision recorded"
        default: return status.capitalized
        }
    }

    static func videoDimensions(from html: String) -> (width: Int, height: Int) {
        let width = html.range(of: #"\"width\"\s*:\s*(\d+)"#, options: .regularExpression).flatMap { Int(html[$0].filter(\.isNumber)) } ?? 1080
        let height = html.range(of: #"\"height\"\s*:\s*(\d+)"#, options: .regularExpression).flatMap { Int(html[$0].filter(\.isNumber)) } ?? 1920
        return (max(1, width), max(1, height))
    }

    private static func sourceIdentity(_ item: [String: Any]) -> (key: String?, title: String?) {
        // Markcut exposes a nonreversible source identity, not local file paths.
        // Use it to group revisions of the same video without leaking paths.
        if let key = item["videoGroupKey"] as? String, !key.isEmpty {
            let title = (item["videoGroupTitle"] as? String) ?? (item["label"] as? String) ?? "Video"
            return ("video:\(key)", humanize(title))
        }
        for field in ["creativeId", "projectId", "creativePath", "projectPath", "sourcePath", "path"] {
            guard let raw = item[field] as? String, !raw.isEmpty else { continue }
            let normalized = raw.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let parent = (normalized as NSString).deletingLastPathComponent
            let leaf = (normalized as NSString).lastPathComponent
            if field.hasSuffix("Id") { return ("identity:\(field):\(raw)", leaf.isEmpty ? field : leaf) }
            let stem = leaf.replacingOccurrences(of: #"\.md$"#, with: "", options: .regularExpression)
            let generic = ["video", "index", "untitled", "review"].contains(stem.lowercased())
            if !parent.isEmpty { return ("parent:\(parent)", generic ? parent.components(separatedBy: "/").last : humanize(stem)) }
            if !generic { return ("source:\(field):\(normalized)", humanize(stem)) }
        }
        let label = (item["title"] as? String) ?? (item["label"] as? String)
        if let label, !label.isEmpty,
           !["video", "video.md", "untitled", "review"].contains(label.lowercased()) {
            return ("label:\(label.lowercased())", humanize(label))
        }
        return (nil, nil)
    }

    private static func revisionTitle(_ item: [String: Any]) -> String {
        let base = (item["title"] as? String) ?? (item["label"] as? String) ?? "Video"
        let date = (item["createdAt"] as? String).map { String($0.prefix(10)) }
        return date.map { "\(humanize(base)) · \($0)" } ?? humanize(base)
    }

    private static func isPending(_ item: [String: Any]) -> Bool {
        (item["status"] as? String) == "ready" && !(item["decision"] is [String: Any])
    }

    private static func timestamp(_ item: [String: Any]) -> String {
        (item["updatedAt"] as? String) ?? (item["createdAt"] as? String) ?? ""
    }

    private static func jobDisplay(_ jobID: String) -> String {
        let trimmed = jobID.trimmingCharacters(in: .whitespacesAndNewlines)
        if UUID(uuidString: trimmed) != nil { return String(trimmed.prefix(8)) }
        return trimmed.count > 18 ? String(trimmed.prefix(15)) + "…" : trimmed
    }

    private static func humanize(_ value: String) -> String {
        value.replacingOccurrences(of: #"\.md$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "[-_]", with: " ", options: .regularExpression)
            .split(separator: " ").map { $0.capitalized }.joined(separator: " ")
    }
}
