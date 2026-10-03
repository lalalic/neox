# NeoY v2 capability migration matrix

| Capability | v2 disposition | Implementation / boundary |
|---|---|---|
| Stable signed menu-bar runtime | **NeoY Core** | `com.neox.neoy`, `LSUIElement`, stable Apple signing identity; Developer ID is the distribution step. |
| Local MCP + Bonjour | **NeoY Core** | Preserve HTTP MCP on 9224 and `_mcp._tcp`. |
| Capture/demo | **NeoY Core** | Native ScreenCaptureKit runtime remains unchanged. |
| Accessibility/computer-use | **NeoY Core** | Native trusted boundary remains narrow; no browser-specific ownership added. |
| Permission status/recovery | **NeoY Core** | Native Accessibility/Screen Recording/camera/mic/notification status plus guided System Settings; Local Network is runtime-probed. |
| Generic shell/filesystem/PTY/job/Codex primitives | **Bundled MacBridge** | Upstream `shell_*`, `fs_*`, `pty_*`, and `codex_thread_*` tools are federated by NeoY; no duplicate Swift stack. |
| User-added MCP federation | **NeoY Core** | Durable configured HTTP MCPs; dynamic namespaced tools `mcp.<server>.<tool>`; text results only. |
| Diagnostics/control state | **NeoY Core** | Schema v2 typed persistence, atomic replacement, malformed-state recovery, explicit v1 migration. |
| NeoX pairing/handoff | **NeoY Core** | Preserve `_neoy._tcp`, port 8686, `POST /agent`, inbox and existing phone MCP selection. |
| NeoX phone media | **First-party integration** | Phone remains authoritative for indexing/search/export; NeoY does not duplicate ownership. |
| Important blocked/failure/completed events | **NeoY Core + NeoX** | NeoY policy filter -> paired NeoX `event.iphone.notify` -> local iOS notification. |
| Browser profiles/tabs/cookies | **Outside Core** | Skill/plugin/federated MCP responsibility. |
| ChatGPT/browser workflow glue | **Outside Core** | Do not recreate MacBridge product-specific automation inside NeoY. |
| Standalone `neoy-bridge.py` | **Retired** | Native NeoY handoff already owns the wire contract. |
| Old Neox Tour app | **Retired** | NeoY is the sole current macOS runtime identity. |

## Retirement gate

Generic predecessor responsibilities are considered replaced only after signed installed-app E2E verifies the corresponding NeoY path. TCC approvals are never synthesized by tests; they are reported as human approval requirements.

Browser/ChatGPT-specific MacBridge behavior is intentionally not part of the replacement set.
