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

Install WebHelm once under `~/.agents/skills/webhelm` and expose its launcher at `~/.local/bin/webhelm` using `scripts/install-global-cli.sh` from that Skill. NeoY runs this installer before its WebHelm health check. Runtime ChatGPT submissions and native setup Session cleanup call this same absolute executable. The removed `browser-workspace` CLI is not a fallback.

Review must check: no duplicate platform implementation or new MCP surface, runtime tests for the global executable, native setup tests for the canonical skill directory, and live `webhelm` status/profile/validate receipts.
