import Foundation

/// Presents incremental speech in the existing composer without permanently
/// rewriting a typed draft. An utterance is submitted separately by the voice
/// outbox; only the temporary recognized suffix is removed on commit.
struct ChatVoiceDraftPreview {
    private(set) var preservedDraft: String?
    private(set) var renderedDraft: String?

    mutating func begin(draft: String) {
        preservedDraft = draft
        renderedDraft = nil
    }

    /// Never clobber text edited by the user while recognition is running.
    mutating func render(transcript: String, currentDraft: String) -> String? {
        guard let base = preservedDraft else { return nil }
        guard currentDraft == (renderedDraft ?? base) else { return nil }
        let pending = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pending.isEmpty else { return nil }
        let separator = base.isEmpty || base.hasSuffix(" ") || base.hasSuffix("\n") ? "" : " "
        let combined = String((base + separator + pending).prefix(2000))
        renderedDraft = combined
        return combined
    }

    /// On auto-send, restore only the preview we own. Keep any manual edits.
    mutating func committed(currentDraft: String) -> String {
        let result = currentDraft == renderedDraft ? (preservedDraft ?? currentDraft) : currentDraft
        preservedDraft = result
        renderedDraft = nil
        return result
    }

    /// Stopping a voice session leaves unsubmitted recognized text in the input.
    mutating func cancel() {
        preservedDraft = nil
        renderedDraft = nil
    }
}
