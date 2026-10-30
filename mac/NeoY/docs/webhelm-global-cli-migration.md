# Global WebHelm CLI migration — 2026-10-29

## Architecture lens

- **Native necessity:** NeoY only provisions and checks the installed browser skill during native setup; the browser runtime and site mechanics remain outside the signed app.
- **Existing owner:** `lalalic/browser-workspace` owns the WebHelm CLI, platform adapters, managed Chrome, and browser Session daemon.
- **Intent and external surface:** No additional MCP methods or public contracts. The existing `chatgpt` lifecycle action continues to accept user intent.
- **Trust boundary:** Only the authenticated NeoY boundary is exposed. No browser control port is exposed externally.
- **Platform identity:** Product state remains with the caller; WebHelm owns browser tabs, sessions, and DOM interactions.
- **Lifecycle semantics:** A `submitted` response is only the verified submission receipt, not final worker completion.
- **Deployment:** This change modifies Swift and the managed Core Runtime. After merge to canonical `main`, run `mac/NeoY/install-local.sh` exactly once and verify the active app and Runtime.

## Integration contract

Install the WebHelm Skill at any location supported by the agent. The agent reads that Skill's `SKILL.md` and runs its installer relative to the loaded Skill file. The installer establishes the global `webhelm` command. NeoY does not resolve a Skill directory or invoke its installer; it calls the global `webhelm` CLI for health checks and browser Sessions. The removed `browser-workspace` CLI is not a fallback.

Review must check: no duplicate platform implementation or new MCP surface, runtime tests for the global executable, native setup tests for a global CLI without any Skill-directory assumption, and live `webhelm` status/profile/validate receipts.
