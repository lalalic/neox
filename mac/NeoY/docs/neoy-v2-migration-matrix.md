# NeoY v2 capability migration matrix

## Evidence base

- **Current native runtime:** `mac/NeoY/Sources/NeoY`, especially the menu-bar application shell, HTTP MCP server, demo recorder, accessibility/computer-use services, and NeoX phone client/handoff receiver.
- **Historical native predecessor:** `mac/NeoxTourMac` at parent commit `f22cdd4^`; it established display capture, tour manifests, and MCP media references before NeoY absorbed them.
- **Historical standalone bridge:** `skills/neox-phone-mcp/scripts/neoy-bridge.py` at parent commit `f22cdd4^`; it established the stable `_neoy._tcp` POST `/agent` queue before the native receiver replaced it.
- **Audit finding:** the current checkout and available repository history contain no separate `MacBridge` product source tree. Historical prose refers to “MacBridge” as a browser/computer-use bridge, while its durable native behavior is represented by NeoY and the two predecessor sources above. This matrix does not invent capabilities for source that is not present.

## Classification

| Capability | Evidence | Disposition | Boundary and next milestone |
|---|---|---|---|
| Signed menu-bar app identity | `mac/NeoY/project.yml` uses `com.neox.neoy`; `install-local.sh` re-signs with a stable development identity; `Resources/Info.plist` sets `LSUIElement`. | **Migrate into NeoY Core** | Keep one stable bundle identity. Later setup/diagnostics must expose identity, version, and service health without changing it. |
| Login launch and crash recovery | `install-local.sh` creates `com.neox.neoy.keepalive` with `RunAtLoad` and `KeepAlive`. | **Migrate into NeoY Core** | v1 installation owns launchd. A later managed startup service must own a durable model, not expose launchd internals as the primary UX. |
| Local MCP serving and Bonjour | `MCPServer.swift` provides JSON-RPC HTTP on 9224 and `_mcp._tcp`. | **Migrate into NeoY Core** | Preserve the current endpoint through the federation milestone. Future federation must be additive and health-visible. |
| Capture tour and native demo recording | `CaptureTour.swift`, `DemoRecorder.swift`, `DemoRuntime.swift`, tour tests. | **Migrate into NeoY Core** | Keep behind native ScreenCaptureKit services. Do not couple recording to a browser or ChatGPT product. |
| Camera/microphone/screen permissions | `Info.plist`, `DemoRecorder.swift`, `NeoYApp.swift`. | **Migrate into NeoY Core** | Native NeoY services retain permission-sensitive work. Setup can inspect and guide permission recovery, but child processes must not be assumed to inherit TCC grants. |
| Accessibility and computer use | `AccessibilityService.swift`, `NeoYAccessibilityController`. | **Migrate into NeoY Core** | Keep a narrow native service seam. Browser-targeted convenience belongs above or outside core, not inside the Mac trust boundary. |
| NeoX pairing handoff | `NeoYHandoff.swift`, `NeoXPhoneClient.swift`, stable `_neoy._tcp` protocol reference. | **Migrate into NeoY Core** | Preserve `_neoy._tcp`, POST `/agent`, port 8686, and inbox behavior. Pairing and events later become setup/diagnostics subjects without breaking NeoX. |
| NeoX phone media tools | `NeoXPhoneClient.swift`, `NeoXPhoneTools.swift`; the phone remains authoritative. | **Expose through first-party integration until federation** | Keep current NeoX behavior. When federation lands, do not duplicate media indexing or export ownership into NeoY. |
| Generic local process startup | v1 has only launch-agent keepalive; no typed process model exists. | **Migrate into NeoY Core later** | Implement the deferred supervisor as a service boundary with cwd/environment, logs, restart policy, and health. Do not seed it with shell glue now. |
| User-added MCP federation | No current implementation exists. | **Migrate into NeoY Core later** | Keep v2 built-ins small; add configured servers through durable agent-first setup and unified health/tool exposure. |
| Permission and diagnostics control | v1 exposes individual tools but no `neoy.setup` control path. | **Migrate into NeoY Core later** | The new read-only `neoy.setup status` is the stable entry. Mutations require validation, persistence, and recovery semantics in later milestones. |
| NeoX important-event notifications | No NeoY notification path exists. | **Migrate into NeoY Core later** | Design a small event contract and durable local queue after pairing diagnostics; do not bundle notifications with generic shell output. |
| Historical browser/ChatGPT demo workflow | Former `NeoxTourMac` README describes using MacBridge to operate Chrome and native apps during a product demo. | **Expose through federation/plugin/skill** | Keep browser sessions, browser-specific authentication, and product-specific scripts out of the Mac core. |
| ChatGPT/browser automation glue and one-off demo orchestration | No browser-specific implementation is in NeoY source; historical prose and external workflows supplied ad-hoc orchestration. | **Retire from Core** | Offer generic process/MCP extension points later; do not recreate ChatGPT or Chrome-specific ownership in NeoY. |
| Standalone Python handoff bridge | `neoy-bridge.py` shells out to `dns-sd` and writes FIFO text files. | **Retire** | The native receiver already replaces this deployment path. Keep only the wire contract, not the Python process or deployment glue. |
| Obsolete `NeoxTourMac` app identity and paths | Former product used `NeoxTourMac` support paths and app name. | **Retire** | NeoY is the current native runtime and owns `com.neox.neoy`; do not maintain two menu-bar capture apps. |

## Non-goals for Core

- Browser profiles, cookies, tabs, or product-specific ChatGPT/browser automation.
- A broad RPC/tool mirror of any predecessor product.
- Arbitrary child-process inheritance of Screen Recording or Accessibility permission.
- Duplicating NeoX media search, metadata, vision indexing, or export authority.
- Making config-file locations the primary user interface.
