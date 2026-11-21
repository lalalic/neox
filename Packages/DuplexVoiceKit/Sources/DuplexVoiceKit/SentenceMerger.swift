import Foundation

/// Merges incremental model text into pronounceable phrases. Text is split only
/// at punctuation or a bounded limit; no incoming fragment is silently lost.
public struct SentenceMerger: Sendable {
    public let maximumCharacters: Int
    private var buffer = ""
    private static let boundaries = Set("。！？!?.；;：:\n")
    private static let softBoundaries = Set("，,、 ")

    public init(maximumCharacters: Int = 180) {
        self.maximumCharacters = max(16, maximumCharacters)
    }

    public mutating func append(_ fragment: String) -> [String] {
        buffer.append(fragment)
        var ready: [String] = []
        while let boundary = nextBoundary() {
            let part = String(buffer[...boundary])
            buffer.removeSubrange(...boundary)
            if !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { ready.append(part) }
        }
        return ready
    }

    public mutating func finish() -> String? {
        let text = buffer
        buffer = ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    private func nextBoundary() -> String.Index? {
        // Don't split an unbounded Unicode phrase at an arbitrary byte offset.
        let prefix = buffer.prefix(maximumCharacters)
        if let hard = prefix.firstIndex(where: { Self.boundaries.contains($0) }) { return hard }
        guard buffer.count >= maximumCharacters else { return nil }
        return prefix.lastIndex(where: { Self.softBoundaries.contains($0) })
            ?? prefix.index(before: prefix.endIndex)
    }
}
