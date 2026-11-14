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
        ["id":"fixture-current", "label":"video-a-v2", "status":"ready", "reviewActionable":true, "createdAt":"2026-11-02T12:00:00Z",
         "updatedAt":"2026-11-02T12:00:00Z",
         "relayCorrelations":[["jobId":"review-fixture-job"]]],
        ["id":"fixture-old", "label":"video-a-v1", "status":"superseded", "createdAt":"2026-11-02T11:00:00Z",
         "updatedAt":"2026-11-02T11:00:00Z",
         "relayCorrelations":[["jobId":"review-fixture-job"]]]
    ] }
    static var multiModeFixture: [[String: Any]] {
        uiFixture + [[
            "id": "fixture-standalone-preview",
            "title": "Standalone text preview",
            "status": "ready",
            "delivery": "text",
            "reviewActionable": false,
            "videoGroupKey": "fixture-standalone-video",
            "createdAt": "2026-11-02T13:00:00Z"
        ]]
    }
    #endif

    static func groups(from sessions: [[String: Any]]) -> [MarkcutReviewGroup] {
        var buckets: [String: [[String: Any]]] = [:]
        for (index, session) in sessions.enumerated() {
            let id = session["id"] as? String ?? "session-\(index)"
            let relayRows = session["relayCorrelations"] as? [[String: Any]] ?? []
            let jobIDs = Array(Set(relayRows.compactMap { $0["jobId"] as? String })).sorted()
            if !jobIDs.isEmpty {
                // A Review row represents one Relay Task, not one Execution.
                // Preserve every revision inside its locally-owned history.
                for jobID in jobIDs {
                    let taskID = relayRows.first(where: { ($0["jobId"] as? String) == jobID })?["taskId"] as? String
                    let key = taskID.map { "job:\(jobID):task:\($0)" } ?? "job:\(jobID)"
                    buckets[key, default: []].append(session)
                }
                continue
            }
            let identity = sourceIdentity(session)
            let key = identity.key ?? "session:\(id)"
            buckets[key, default: []].append(session)
        }
        return buckets.map { key, values in
            let ordered = values.sorted { timestamp($0) > timestamp($1) }
            let jobID = key.hasPrefix("job:") ? String(key.dropFirst("job:".count)).components(separatedBy: ":task:").first : nil
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

    // The Inbox is a flat chronological list, but a multi-revision Relay Job
    // still needs its Job ID on EVERY row. Never replace it with an internal
    // .ghost.*.md artifact title just because the group has multiple revisions.
    static func rowTitle(group: MarkcutReviewGroup, revision: MarkcutReviewGroup.Revision,
                         jobTitles: [String: String] = [:]) -> String {
        let source = revision.value["title"] as? String ?? ""
        // An explicit caller title always wins over the Relay default.
        if revision.value["customTitle"] as? Bool == true, !source.hasPrefix(".ghost.") {
            return source
        }
        if let id = group.jobID {
            if let title = jobTitles[id], !title.isEmpty { return "\(id):\(title)" }
            if source.hasPrefix("\(id):") { return source }
            if let groupTitle = revision.value["videoGroupTitle"] as? String,
               groupTitle.hasPrefix("\(id):") { return groupTitle }
            return id // Never expose a private ghost artifact while metadata loads.
        }
        return group.sessions.count > 1 ? revision.title : group.title
    }

    static func rowSubtitle(_ item: [String: Any], taskTitles: [String: String] = [:]) -> String {
        if let subtitle = item["subtitle"] as? String, !subtitle.isEmpty { return subtitle }
        // Legacy requests created before the Review wrapper supplied subtitles.
        if let row = (item["relayCorrelations"] as? [[String: Any]])?.first,
           let jobID = row["jobId"] as? String,
           let taskID = row["taskId"] as? String {
            let name = taskTitles["\(jobID)/\(taskID)"] ?? "Task"
            return "\(taskID):\(name)"
        }
        return statusText(item)
    }

    static func statusText(_ item: [String: Any]) -> String {
        if let decision = item["decision"] as? [String: Any], let value = decision["decision"] as? String {
            return value == "approved" ? "Approved" : "Changes requested"
        }
        let status = item["status"] as? String ?? "pending"
        switch status {
        case "ready": return (item["reviewActionable"] as? Bool ?? true) ? "Pending review" : "Preview only"
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
        // Group by the Master-provided source identity. Some legacy keys are
        // absolute local paths: use them only for grouping, never display them.
        if let key = item["videoGroupKey"] as? String, !key.isEmpty {
            let explicit = item["videoGroupTitle"] as? String
            let raw = explicit ?? ((item["title"] as? String) ?? (item["label"] as? String) ?? "Video")
            let title = explicit.map(displayRunTitle) ?? runDisplayTitle(groupKey: key, fallback: raw)
            return ("video:\(key)", title)
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
        var base = (item["title"] as? String) ?? (item["label"] as? String) ?? "Video"
        if ["video", "video.md", "untitled"].contains(base.lowercased()),
           let variant = item["videoItemTitle"] as? String { base = variant }
        if ["video", "video.md", "untitled"].contains(base.lowercased()),
           let relay = (item["relayCorrelations"] as? [[String: Any]])?.first,
           let task = relay["taskId"] { base = "Task \(task)" }
        let date = (item["createdAt"] as? String).map { localDate($0) }
        return date.map { "\(humanize(base)) · \($0)" } ?? humanize(base)
    }

    static func localDate(_ timestamp: String, timeZone: TimeZone = .current) -> String {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp) else {
            return String(timestamp.prefix(10))
        }
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func isPending(_ item: [String: Any]) -> Bool {
        (item["status"] as? String) == "ready" &&
            ((item["reviewActionable"] as? Bool) ?? true) && !(item["decision"] is [String: Any])
    }

    private static func timestamp(_ item: [String: Any]) -> String {
        (item["updatedAt"] as? String) ?? (item["createdAt"] as? String) ?? ""
    }

    private static func jobDisplay(_ jobID: String) -> String {
        let trimmed = jobID.trimmingCharacters(in: .whitespacesAndNewlines)
        if UUID(uuidString: trimmed) != nil { return String(trimmed.prefix(8)) }
        return trimmed.count > 18 ? String(trimmed.prefix(15)) + "…" : trimmed
    }

    /// The Master groups by a private source key. Render only the dated run
    /// folder and the video variant, never the source's absolute Mac path.
    private static func runDisplayTitle(groupKey: String, fallback: String) -> String {
        let components = groupKey.split(separator: "/").map(String.init)
        if let runsIndex = components.lastIndex(of: "runs"),
           runsIndex + 1 < components.count {
            let afterRuns = components.dropFirst(runsIndex + 1)
            // Supports runs/YYYY-MM-DD-name and runs/series/YYYY-MM-DD-name.
            let run = afterRuns.first(where: { value in
                value.range(of: #"^\d{4}-\d{2}-\d{2}-"#, options: .regularExpression) != nil
            })
            if let run {
                let source = components.last ?? ""
                let stem = source.replacingOccurrences(of: #"\.md$"#, with: "", options: .regularExpression)
                let title = displayRunTitle(run)
                if !["video", "index", "untitled", "review"].contains(stem.lowercased()),
                   !stem.isEmpty {
                    return humanize(stem) + " · " + title
                }
                return title
            }
        }
        return displayRunTitle(fallback)
    }

    private static func displayRunTitle(_ value: String) -> String {
        // Display a dated creative run concisely inside the iPhone sheet title.
        // The opaque group key, not this label, determines identity.
        let chunks = value.split(separator: "-", omittingEmptySubsequences: false)
        if chunks.count >= 4, chunks[0].count == 4, chunks[1].count == 2,
           chunks[2].count == 2, chunks.prefix(3).allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            let name = chunks.dropFirst(3).joined(separator: "-")
            if !name.isEmpty { return "\(humanize(name)) · \(chunks[1])/\(chunks[2])" }
        }
        return humanize(value)
    }

    private static func humanize(_ value: String) -> String {
        if value.lowercased().hasPrefix(".ghost.") { return "Preview" }
        return value.replacingOccurrences(of: #"\.md$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "[-_]", with: " ", options: .regularExpression)
            .split(separator: " ").map { $0.capitalized }.joined(separator: " ")
    }
}
