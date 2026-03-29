# Deep Dive: Multi-Modal Input

## The Vision
Your phone is a sensor array — camera, mic, screen, files. The agent should be able to use ALL of them as input. This isn't just "attach an image" — it's making the physical world an input channel for development.

---

## Input Modalities

### 1. Camera → Agent Sees What You See

**Capture modes:**
- **Snap & Ask** — Take a photo, add a prompt. "What's wrong with this layout?"
- **Live Camera** — Agent continuously analyzes camera feed (CameraKit's `observe_camera`). "I'm looking at a whiteboard, transcribe the architecture diagram."
- **Screen Capture** — Screenshot your phone screen or another app → send to agent

**Dev scenarios:**
| You Point At | Agent Does |
|-------------|-----------|
| Whiteboard sketch | Generates UI code matching the layout |
| Error on monitor | Reads error message, explains fix, writes the fix |
| Paper napkin wireframe | Converts to SwiftUI/HTML mockup |
| Design in Figma (on another screen) | "Recreate this in code" → generates matching UI |
| Physical product | "Build a product page for this item" → agent describes it, generates landing page |
| Printed QR code / URL | Navigates browser to it, starts automation |
| Book page / docs | Summarizes, extracts code examples |

**Implementation:**
```swift
// CopilotSDK already supports this directly
let imageData = camera.getLatestFrameBase64(quality: 0.1)
try await session.sendWithImage(imageData, mimeType: "image/jpeg", text: userPrompt)
```

### 2. Voice → Natural Language Everything

**Beyond simple dictation:**
- **Conversational coding** — "Make the button bigger… no, the blue one… yeah, now add a shadow"
- **Walk-and-talk dev** — Describe what you want while walking. Agent builds it.
- **Code review by voice** — Agent reads code aloud, you approve/reject changes verbally
- **Ambient listening** — Hands-free mode where agent listens for wake word, then takes instructions

**Voice + Camera combined:**
- "I'm looking at [camera feed] — what framework is this using?" 
- Point at screen → "Fix this" (agent sees the error AND hears your frustration context)
- "Record a video of me demonstrating the bug" → agent watches, diagnoses

**Implementation:**
```swift
// CameraKit voice services
let voiceIn = VoiceInput()
let prompt = await voiceIn.listen(duration: 10)  // 10sec recording

let voiceOut = VoiceOutput()
voiceOut.speak("I've fixed the layout. The margin was 8px, I changed it to 16px.")
```

### 3. Files & Documents

**File types as input:**
| Input | What Agent Does |
|-------|----------------|
| `.swift` / `.ts` file | Review, refactor, explain, test |
| `.png` / `.jpg` design mockup | Generate code matching the design |
| `.pdf` spec document | Extract requirements, create tasks |
| `.json` API response | Generate model types, validate schema |
| Xcode project | Analyze structure, suggest improvements |
| Share sheet from other apps | "Shared a URL from Safari" → agent browses + analyzes |

**Implementation:**
```swift
try await session.sendWithFile(path: filePath, displayName: "design.png", text: "Build this UI")
```

### 4. Clipboard & Share Sheet

- Copy text/image in any app → open Neox → auto-detects clipboard content
- iOS Share Sheet extension → "Share to Neox Agent"
  - Share a URL → agent navigates to it
  - Share an image → agent analyzes it  
  - Share text/code → agent processes it
- Deep link support: `neox://ask?prompt=...`

### 5. Screen Recording → Agent Watches You

- Record yourself using an app → agent sees the recording
- "I recorded a bug — here's the screen recording. What's happening?"
- Agent can step through frames, identify the issue

---

## Smart Input Detection

The app should be intelligent about what you're giving it:

```
User sends photo:
  → Contains text/code? → OCR extract → "I see Python code with a NameError on line 12..."
  → Contains UI? → "This is a login screen with email/password fields..."
  → Contains diagram? → "This is a flowchart showing user auth flow..."
  → Contains physical object? → "This is a [product]. Want me to build a page for it?"
```

**Scene analysis via CameraKit's `SceneAnalyzer`:**
```swift
let analysis = await analyzer.analyze(pixelBuffer: frame)
// Returns: scene labels, detected text, objects, lighting conditions
// Agent pre-processes this context before sending to LLM
```

---

## Multi-Modal Prompt Composer

### UI Design
```
┌─────────────────────────────────────┐
│  [Camera] [Gallery] [Files] [Mic]   │  ← input mode selector
├─────────────────────────────────────┤
│  ┌──────────┐                       │
│  │ 📷       │  "Build a login page  │  ← attached media + text
│  │ preview  │   like this design"   │
│  └──────────┘                       │
├─────────────────────────────────────┤
│  [Send]                    [Voice]  │
└─────────────────────────────────────┘
```

- Attach multiple items: photo + file + voice note
- Preview attachments before sending
- Voice note auto-transcribed, shown as editable text
- Camera quick capture without leaving chat

---

## Agentic Multi-Modal Loops

The agent can REQUEST input from the user:

```
Agent: "I need to see your current UI to fix the layout. Can you take a screenshot?"
→ App shows camera/screenshot prompt
→ User captures
→ Agent receives and continues

Agent: "Can you show me the error on your screen?"
→ Opens camera view
→ User points at monitor
→ Agent reads error, generates fix

Agent: "Say the name of the variable you want to rename"
→ Activates mic
→ User says "userAuthToken"
→ Agent performs rename
```

This is powered by CopilotSDK's `onUserInputRequest` / `ask_user` tool — the agent can ask the user questions AND request specific input types.

---

## Privacy Considerations

- Camera/mic input stays local until explicitly sent to agent
- On-device scene analysis (CameraKit + Vision) pre-processes before cloud
- Option to use Apple Foundation Models (iOS 26+) for fully on-device processing
- Clear indicators when camera/mic are active
- No persistent storage of camera frames without user consent

---

## MVP Multi-Modal Features (v0.1)

1. **Photo attachment** — camera button in chat, take photo, add text prompt
2. **Voice input** — hold mic button, speech-to-text, send as text prompt
3. **File sharing** — share sheet extension to receive files from other apps

## v0.2
4. Voice output (TTS for agent responses)
5. Smart input detection (auto-classify image content)
6. Clipboard auto-detect

## v0.3
7. Live camera feed analysis
8. Agent-initiated input requests
9. Multi-attachment prompts
10. Screen recording analysis
