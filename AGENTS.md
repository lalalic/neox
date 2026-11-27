# Neox — project knowledge

Neox owns native iOS media, MCP and Neo Mobile UI, plus the macOS Neo.app/NeoY native trust boundary. The separate Neo Harness and Agents Relay own their CLI, reusable Skills and durable work lifecycle. Reuse AppCopilotKit for UI automation, never vendor it.

## Current design references

| Task | Read on demand |
| --- | --- |
| macOS architecture and authority | [Design principles](mac/NeoY/docs/design-principles.md), [architecture](mac/NeoY/docs/neoy-v2-architecture.md) |
| Mobile chat, Jobs, review, media, device tests | [Mobile engineering](docs/mobile-engineering.md), [README](README.md), [phone skill](skills/neox-phone-mcp/SKILL.md) |
| Native app / Core deployment | [Local deployment](mac/NeoY/docs/local-deployment.md), [distribution](mac/NeoY/docs/distribution.md) |
| Harness setup and package ownership | [Setup contract](mac/NeoY/docs/neo-harness-setup-contract.md) |
| Voice, accessibility, remote exposure | [Voice](mac/NeoY/docs/neoy-listen-talk.md), [shared tunnel](mac/NeoY/docs/shared-cloudflare-tunnel.md) |
| MCP diagnosis | [Tool-call audit](mac/NeoY/docs/tool-call-audit.md) |

Design, Planner, Implementation and Reviewer read this entry and only relevant references; use `code-intelligence` to inspect actual source. For every NeoY change read its design principles, explicitly answer applicable Architecture Lens questions in the plan and review those answers against the diff. No parallel ownership, browser mechanics in business state, unnecessary native surface, or acknowledgement-as-completion.

## Engineering invariants

- Preserve authenticated gateway ownership, stable permissions/bundle identity, device and session isolation. Never treat nearby Bonjour discovery as remote online proof or redirect bound credentials. Keep Jobs authoritative; no direct Relay store reads.
- Preserve explicit Apply for exposure/address drafts; keep mandatory infrastructure distinct from optional Features. Feature tools derive from live tools/list; install and health receipts are separate. Never overwrite unowned Skill sources. Run SwiftUI AXPress actions on the main actor.
- Keep one bounded filesystem facade and canonical provider lifecycle; child replacement requires unpublish, reinitialize, probe and republish. No leaked secrets in public evidence. Use user-selected security-scoped folders when applicable and ready markers only after bytes are complete.
- Keep media MCP range streaming, trusted-only UI control and shared AppCopilotKit. Real device/UI/transport verification is distinct from compile or simulator results.

## Delivery

For authorized local deployment follow the [deployment contract](mac/NeoY/docs/local-deployment.md). Runtime-only changes use managed Core upgrade without native app restart; native changes use the canonical installer directly exactly once, never supervised/retried or bypassed. Verify installed health, provider readiness and task-specific behavior. Use the existing Neo.app Cloudflare connector for hostname changes. For tool failures correlate actual terminal status, process exit and job identity; a running shell response is not failure and must not be blindly retried.
