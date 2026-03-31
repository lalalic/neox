# Design: Lazy Attachment Loading

> **Status:** Refined — user confirmed auto-resize approach, ready for review  
> **Priority:** P2  
> **Date:** 2025-07-17 (refined 2025-07-17)

---

## 1. Problem Statement

Current attachment flow sends file data **eagerly** — the full base64-encoded image/file content is embedded directly in the `session.send` message. This is wasteful when:

- User attaches **multiple files** (e.g., 10 photos for a vlog project)
- Model only needs to **inspect a few** of them
- Large files (videos, PDFs) bloat the context window even if the model just needs metadata
- Model might want to **process files sequentially** rather than receiving all at once

**Proposed:** Send only **file paths/metadata** with the message. The model calls a `get_attachment` tool when it actually needs file content.

---

## 2. Current Flow (Eager)

```
User: "Here are 5 photos, pick the best one for a thumbnail"
  + [photo1.jpg 2MB] [photo2.jpg 1.8MB] [photo3.jpg 2.1MB] [photo4.jpg 1.5MB] [photo5.jpg 1.9MB]

session.send({
  prompt: "Here are 5 photos, pick the best one for a thumbnail",
  attachments: [
    { type: "blob", data: "<2MB base64>", mimeType: "image/jpeg" },
    { type: "blob", data: "<1.8MB base64>", mimeType: "image/jpeg" },
    { type: "blob", data: "<2.1MB base64>", mimeType: "image/jpeg" },
    { type: "blob", data: "<1.5MB base64>", mimeType: "image/jpeg" },
    { type: "blob", data: "<1.9MB base64>", mimeType: "image/jpeg" },
  ]
})

→ ~13MB of base64 in a single message
→ All 5 images consume context tokens even if model only needs 2
→ Relay WebSocket bandwidth spike
```

## 3. Proposed Flow (Lazy)

```
User: "Here are 5 photos, pick the best one for a thumbnail"
  + [photo1.jpg] [photo2.jpg] [photo3.jpg] [photo4.jpg] [photo5.jpg]

session.send({
  prompt: "Here are 5 photos, pick the best one for a thumbnail\n\nAttached files:\n1. photo1.jpg (2.0 MB, image/jpeg)\n2. photo2.jpg (1.8 MB, image/jpeg)\n3. photo3.jpg (2.1 MB, image/jpeg)\n4. photo4.jpg (1.5 MB, image/jpeg)\n5. photo5.jpg (1.9 MB, image/jpeg)\n\nUse the get_attachment tool to view any file.",
  attachments: []  // No inline data!
})

Model: get_attachment({ name: "photo1.jpg" })  → receives base64 of photo1 only
Model: get_attachment({ name: "photo3.jpg" })  → receives base64 of photo3 only
Model: "photo3.jpg has the best composition for a thumbnail."
  
→ Only 2 images fetched (~5.5MB vs 13MB)
→ Model sees file list in prompt, decides what to fetch
→ Works with any file type (images, videos, documents)
```

---

## 4. Architecture

```
┌──────────────────────────────────────────────┐
│  iOS App                                     │
│                                              │
│  User selects files → AttachmentPicker       │
│       │                                      │
│       ▼                                      │
│  AttachmentStore (in-memory)                 │
│  ┌──────────────────────────────────────────┐│
│  │ "photo1.jpg" → /tmp/photo1.jpg (2.0 MB) ││
│  │ "photo2.jpg" → /tmp/photo2.jpg (1.8 MB) ││
│  │ "spec.pdf"   → /tmp/spec.pdf   (500 KB) ││
│  └──────────────────────────────────────────┘│
│       │                                      │
│       ▼                                      │
│  ChatViewModel.send()                        │
│  → Prompt includes file list (names + sizes) │
│  → NO inline attachment data                 │
│                                              │
│  get_attachment tool (registered per session) │
│  → Reads from AttachmentStore by name        │
│  → Returns base64 data to model              │
│                                              │
│  save_to_workspace tool (existing)           │
│  → Model can also copy files to workspace    │
└──────────────────────────────────────────────┘
```

---

## 5. Component Design

### 5.1 AttachmentStore

```swift
/// Per-session store for lazily-provided attachments.
/// Files are referenced by display name and loaded on demand.
@MainActor
public class AttachmentStore: ObservableObject {
    struct Entry {
        let url: URL
        let displayName: String
        let mimeType: String
        let fileSize: Int64
    }
    
    @Published var entries: [Entry] = []
    
    func add(url: URL) {
        let name = url.lastPathComponent
        let mimeType = mimeTypeForExtension(url.pathExtension)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        entries.append(Entry(url: url, displayName: name, mimeType: mimeType, fileSize: fileSize))
    }
    
    func remove(at index: Int) {
        entries.remove(at: index)
    }
    
    func clear() {
        entries.removeAll()
    }
    
    /// Generate the text description for the prompt
    func promptDescription() -> String? {
        guard !entries.isEmpty else { return nil }
        var lines = ["", "Attached files:"]
        for (i, entry) in entries.enumerated() {
            let sizeStr = ByteCountFormatter.string(fromByteCount: entry.fileSize, countStyle: .file)
            lines.append("\(i + 1). \(entry.displayName) (\(sizeStr), \(entry.mimeType))")
        }
        lines.append("")
        lines.append("Use the get_attachment tool to view/read any file content.")
        return lines.joined(separator: "\n")
    }
    
    /// Load file data by name (called by get_attachment tool handler)
    func loadData(name: String) throws -> (Data, String) {
        guard let entry = entries.first(where: { $0.displayName == name }) else {
            throw AttachmentError.notFound(name)
        }
        let data = try Data(contentsOf: entry.url)
        return (data, entry.mimeType)
    }
}
```

### 5.2 get_attachment Tool

```swift
/// Tool registered on each session for lazy attachment loading.
func makeGetAttachmentTool(store: AttachmentStore) -> ToolDefinition {
    ToolDefinition(
        name: "get_attachment",
        description: "Get the content of an attached file by name. Returns base64-encoded data for binary files, or text content for text files.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "name": .object([
                    "type": .string("string"),
                    "description": .string("The filename of the attachment to retrieve")
                ]),
            ]),
            "required": .array([.string("name")])
        ]),
        handler: { args in
            guard case .object(let dict) = args,
                  case .string(let name) = dict["name"] else {
                return "Error: 'name' parameter is required"
            }
            
            do {
                let (data, mimeType) = try await MainActor.run {
                    try store.loadData(name: name)
                }
                
                if mimeType.hasPrefix("text/") || isTextFile(name) {
                    // Return text content directly
                    return String(data: data, encoding: .utf8) ?? "Error: Unable to decode text"
                } else if mimeType.hasPrefix("image/") {
                    // Return as base64 with mime type prefix for vision models
                    let base64 = data.base64EncodedString()
                    return "data:\(mimeType);base64,\(base64)"
                } else {
                    // Binary file — return base64
                    let base64 = data.base64EncodedString()
                    return "[\(name)] base64:\(base64)"
                }
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        }
    )
}
```

### 5.3 Modified Send Flow

```swift
// In ChatViewModel:

public func send() async {
    let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    inputText = ""
    
    // Build prompt with attachment descriptions
    var fullPrompt = text
    if let attachmentDesc = attachmentStore.promptDescription() {
        fullPrompt += attachmentDesc
    }
    
    // Add user message to chat (with attachment thumbnails)
    var blocks: [ChatMessage.ContentBlock] = [.text(text)]
    for entry in attachmentStore.entries {
        blocks.append(.attachment(entry.url, name: entry.displayName))
    }
    messages.append(ChatMessage(role: .user, content: blocks))
    
    // Send with NO inline attachments — tool handles data loading
    chatState = .working
    await sendPrompt(fullPrompt)
    
    // Clear attachment store after send
    attachmentStore.clear()
}
```

### 5.4 UI Changes

**InputBar attachment preview strip:**

```
┌─────────────────────────────────────────┐
│ [📷 photo1.jpg ✕] [📷 photo2.jpg ✕]    │ ← removable chips
│ [📄 spec.pdf ✕]                         │
├─────────────────────────────────────────┤
│ [📎] Pick the best photo for...    [➤] │
└─────────────────────────────────────────┘
```

- Attachment chips show above the text field
- Each chip has an ✕ to remove
- Photos show small preview thumbnail
- File size shown on long press

**Multi-select support:**
- Photo picker: change `selectionLimit` from 1 to 10
- Document picker: allow multiple selection

---

## 6. Edge Cases

| Case | Handling |
|------|----------|
| Model requests non-existent file | Return error string: "Attachment 'xyz.jpg' not found" |
| File deleted after attach | Return error: "File no longer available at original path" → suggest user re-attach |
| Very large file (>100MB video) | Return metadata only: "File too large for inline transfer. Use save_to_workspace to copy to project directory, then process with ffmpeg." |
| Multiple files with same name | Deduplicate: append `-2`, `-3` etc. |
| Session ends with unfetched attachments | No cleanup needed — AttachmentStore is in-memory, cleared on session end |

---

## 7. Backward Compatibility

The `sendWithImage` method still exists for single-image quick-send (camera capture). Lazy loading is specifically for the multi-file attachment workflow.

| Method | When | Data Flow |
|--------|------|-----------|
| `sendWithImage()` | Camera capture, single image | Inline base64 (eager) |
| `send()` + `AttachmentStore` | File picker, multi-file | Lazy via get_attachment tool |

---

## 8. Benefits

| Metric | Eager (Current) | Lazy (Proposed) |
|--------|-----------------|-----------------|
| 5 photos, model needs 2 | ~13MB sent, all 5 in context | ~5.5MB sent, only 2 in context |
| 10 files, model needs 1 | All 10 loaded upfront | Only 1 loaded on demand |
| Context window usage | All attachments consume tokens | Only fetched items consume tokens |
| WebSocket bandwidth | Spike on send | Distributed across tool calls |
| User experience | Slow send, long wait | Fast send, progressive loading |

---

## 9. Implementation Phases

### Phase 1: Core Tool + Store
1. **CopilotChat**: `AttachmentStore` class
2. **CopilotChat**: `get_attachment` tool definition
3. **ChatViewModel**: Modified send flow (prompt includes file list)
4. **ChatViewModel**: Register `get_attachment` tool on session creation

### Phase 2: Multi-Select UI
5. **AttachmentPicker**: Multi-select photo picker (`selectionLimit: 10`)
6. **AttachmentPicker**: Multi-select document picker
7. **InputBar**: Attachment chip preview strip
8. **InputBar**: Remove individual attachment

### Phase 3: Smart Loading
9. **AttachmentStore**: Thumbnail generation for image previews in chat
10. **get_attachment**: Smart sizing — return downscaled image if model doesn't need full res
11. **get_attachment**: Text extraction from PDFs (use PDFKit)
12. **get_attachment**: Video metadata (duration, resolution) without full content

---

## 10. Open Questions

1. **Image quality**: Should `get_attachment` for images auto-resize to reasonable dims (e.g., 1024px max) to save tokens? Or respect original?
2. **File retention**: Should files be copied to workspace on attach (persistent) or kept as temp references (transient)?
3. **Video handling**: For video files, should `get_attachment` return a screenshot/thumbnail, or metadata, or refuse?
4. **Mixed mode**: Should users be able to choose eager vs lazy per-attachment?
