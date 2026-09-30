# NeoY v2.2 DevMacBridge replacement matrix

NeoY 2.2 copies DevMacBridge **capabilities**, not its one-tool-per-operation MCP
surface.

| DevMacBridge dependency | NeoY 2.2 equivalent | Evidence |
|---|---|---|
| synchronous shell exec | `mac.exec run` | installed-app E2E: exit 0, stdout `v22-ok` |
| long-running shell jobs | `mac.exec start/jobs/status/logs/stop` | installed-app E2E: background job started, logs read, stopped |
| PTY interactive terminal | `mac.exec pty start/read/write/resize/signal/close` | installed-app E2E using `/bin/cat`, write/read/resize/close |
| generic filesystem | `mac.fs` | installed-app E2E write/read plus focused tests |
| Codex thread list/read/turns | `codex.threads` | installed-app real `codex app-server` thread list |
| setup/configuration | `neoy.setup` | existing v2.1 surface extended with capabilities/auth |
| work/home node wrapper tools | `node` canonical Core forwarding | implementation + local canonical-contract tests; real second-node E2E still required before retiring DevMacBridge |
| browser/Chrome/ChatGPT UI glue | outside Core | skill/plugin/federated MCP |
| SaaS-specific APIs | outside Core | connectors/federated MCP |

## Trust boundary

- Direct loopback MCP is privileged.
- Core and user-federated MCP tools are marked protected.
- Public/tunneled `tools/list` hides protected Core tools without a valid NeoY Core token.
- A protected `tools/call` without trust is rejected.
- Remote node pairing is explicit and stores peer credentials mode `0600`.
- Optional first-party capabilities are enabled by default and can be disabled;
  the corresponding tools disappear from `tools/list`.

## Validation

- NeoY XCTest: **21/21 passed**.
- Signed installed app: `/Applications/NeoY.app`, stable `com.neox.neoy` identity.
- Runtime version: **2.2.0**.
- Local Core E2E: shell, background jobs, PTY, filesystem, Codex history.
- Optional capability E2E: `demo-recording` changed from 18 visible demo tools
  to 0 when disabled, then restored to 18 after re-enable.
- Public named tunnel `https://neoy.qili2.com/mcp`: unauthenticated
  `tools/list` remained compatible with the existing optional/plugin surface
  while exposing **zero** of the five privileged Core tools.
- PM2 `neoy` and named tunnel remained online during v2.2 validation.

## Retirement gate

The current environment's legacy remote-node connector returned `Unknown tool`
for both configured remote-node execution surfaces, so a real second-Mac NeoY
pairing/invocation could not be performed in this run.

Therefore NeoY 2.2 implements the replacement surface, but **DevMacBridge should
not yet be retired**. Final retirement requires one real remote NeoY E2E plus a
NeoY-only rerun of the workflows that currently depend on DevMacBridge.
