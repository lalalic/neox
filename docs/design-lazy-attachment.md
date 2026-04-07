# Design: Lazy Attachment Loading

> **Status:** Revised — `view` tool (image-only) replaces `get_attachment`  
> **Priority:** P2  
> **Date:** 2025-07-17 (revised 2025-07-18)

---

## 1. Problem Statement

Current attachment flow sends file data **eagerly** — the full base64-encoded image/file content is embedded directly in the `session.send` message. This is wasteful when:

- User attaches **multiple files** (e.g., 10 photos for a vlog project)
- Model only needs to **inspect a few** of them
- Large files (videos, PDFs) bloat the context window even if the model just needs metadata
- Model might want to **process files sequentially** rather than receiving all at once

**Proposed:** Send only **file paths/metadata** with the message. The model calls a `view` tool to see image content on demand. Non-image files (text, code) are included inline in the prompt.

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
  prompt: "Here are 5 photos, pick the best one for a thumbnail\n\nAttached images:\n1. photo1.jpg (2.0 MB)\n2. photo2.jpg (1.8 MB)\n3. photo3.jpg (2.1 MB)\n4. photo4.jpg (1.5 MB)\n5. photo5.jpg (1.9 MB)\n\nUse the view tool to see any image.",
  attachments: []  // No inline data!
})

Model: view({ path: "photo1.jpg" })  → receives resized base64 of photo1
Model: view({ path: "photo3.jpg" })  → receives resized base64 of photo3
Model: "photo3.jpg has the best composition for a thumbnail."
  
→ Only 2 images fetched (~5.5MB vs 13MB)
→ Model sees image list in prompt, views on demand
→ Image-only — text/code files are included inline
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
│  → Images: listed by name/size (lazy)        │
│  → Text/code: included inline in prompt      │
│  → NO inline image data                      │
│                                              │
│  view tool (registered per session)           │
│  → Reads image from AttachmentStore by name  │
│  → Auto-resizes to 1024px max                │
│  → Returns base64 for vision model           │
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
        lines.append("Use the `view` tool to see any image.")
        return lines.joined(separator: "\n")
    }
    
    /// Load file data by name (called by view tool handler)
    func loadData(name: String) throws -> (Data, String) {
        guard let entry = entries.first(where: { $0.displayName == name }) else {
            throw AttachmentError.notFound(name)
        }
        let data = try Data(contentsOf: entry.url)
        return (data, entry.mimeType)
    }
}
```

### 5.2 view Tool (Image Only)

The `view` tool replaces `get_attachment`. It only handles images — text/code files are included inline in the prompt.

```swift
func makeViewTool(store: AttachmentStore) -> ToolDefinition {
    ToolDefinition(
        name: "view",
        description: "View an image by name or path. Returns auto-resized base64 image data for vision. Only works with image files.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Image filename from the attached files list, or a workspace file path")
                ]),
            ]),
            "required": .array([.string("path")])
        ]),
        handler: { args in
            guard case .object(let dict) = args,
                  case .string(let path) = dict["path"] else {
                return "Error: 'path' parameter is required"
            }
            
            do {
                let result = try await store.loadSmart(name: path)
                return result.modelDescription
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        }
    )
}
```
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
| `send()` + `AttachmentStore` | File picker, multi-file | Images lazy via `view` tool, text inline |

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
1. **CopilotChat**: `AttachmentStore` class ✅ (already exists)
2. **CopilotChat**: `view` tool definition (image-only)
3. **ChatViewModel**: Modified send flow (images listed, text inline)
4. **ChatViewModel**: Register `view` tool on session creation

### Phase 2: Multi-Select UI
5. **AttachmentPicker**: Multi-select photo picker (`selectionLimit: 10`)
6. **AttachmentPicker**: Multi-select document picker
7. **InputBar**: Attachment chip preview strip
8. **InputBar**: Remove individual attachment

### Phase 3: Smart Loading
9. **AttachmentStore**: Thumbnail generation for image previews in chat
10. **view**: Smart sizing — return downscaled image if model doesn't need full res ✅ (loadSmart already does this)
11. ~~**get_attachment**: Text extraction from PDFs~~ (not needed — text files inline)
12. ~~**get_attachment**: Video metadata~~ (not needed — view is image-only)

---

## 10. Open Questions

1. **Image quality**: `view` auto-resizes to 1024px max ✅ (handled by loadSmart)
2. **File retention**: Files kept as temp references (transient) — cleared on session end
3. ~~**Video handling**: Not applicable — `view` is image-only~~
4. ~~**Mixed mode**: Not applicable — images lazy, text inline~~
