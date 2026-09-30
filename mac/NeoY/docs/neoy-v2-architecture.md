# NeoY v2 architecture

## Objective

NeoY is Neo's signed, always-on macOS runtime and control plane. It stays menu-bar/headless-first and keeps the privileged Mac trust boundary native. Agents configure it through one compact command surface rather than a growing collection of setup tools.

## Runtime shape

```text
AI agent
   |
   v
neoy.setup(command)
   |
   +--> ControlPlane schema v2
   |      +-- diagnostics
   |      +-- startup services
   |      +-- MCP servers
   |      +-- important-event policy
   |
   +--> PermissionService --------> macOS TCC / System Settings
   +--> StartupSupervisor --------> Process + cwd/env/logs/restart
   +--> MCPFederation ------------> user-configured HTTP MCP servers
   +--> NeoX event bridge --------> paired NeoX event.notify
   |
   +--> existing native tools
          capture/demo | accessibility/computer-use | phone media/handoff
```

The built-in control surface remains **one** MCP tool: `neoy.setup`. Runtime capabilities are implemented behind typed services so adding configuration does not expand the core MCP surface.

## Stable identity and trust

- Bundle identifier remains `com.neox.neoy`.
- `LSUIElement` and accessory activation preserve the menu-bar/headless product shape.
- Local installs use a stable Apple Development signing identity through `install-local.sh`; production distribution should use the corresponding Developer ID identity without changing the bundle identifier.
- Screen Recording, Accessibility, camera, microphone, notification, and Local Network approval remain human/macOS-controlled. NeoY can inspect supported states and open the relevant System Settings pane, but it never bypasses TCC.
- Permission-sensitive work stays native. Supervised child processes are not assumed to inherit NeoY's TCC grants.

## Agent-facing setup contract

```text
help [topic]
status
config show

diagnostics enable|disable
diagnostics set level <info|warning|error>
diagnostics set retention-days <1...365>

permissions status
permissions open <accessibility|screen-recording|camera|microphone|notifications|local-network>

startup list
startup add <name> <absolute-executable> [args...]
startup remove|enable|disable <name>
startup set cwd <name> <absolute-path|none>
startup set restart <name> <never|on-failure|always>
startup set env <name> <KEY> <VALUE>
startup set unset-env <name> <KEY>

mcp list
mcp add <name> <http(s)-mcp-url>
mcp remove|enable|disable <name>

events status
events enable|disable <blocked|failure|completed>
events notify <kind> "<title>" <body...>
```

`help` is authoritative for the installed version. Unknown commands fail explicitly.

## Durable configuration

Schema version 2 stores validated typed state for diagnostics, startup services, federated MCP servers, and important-event policy. Writes validate before replacement. Malformed state is preserved to a timestamped invalid-state file and replaced with validated defaults while health reports the recovery. Schema v1 diagnostics-only state migrates explicitly to v2 without losing diagnostics settings.

Config-file paths are an implementation detail, not the normal UX.

## Startup supervision

`NeoYStartupSupervisor` owns named processes using Foundation `Process`, not shell interpolation. Each service can define:

- absolute executable and argument vector;
- working directory;
- environment overrides;
- enable/disable;
- restart policy: `never`, `on-failure`, or `always`;
- stdout/stderr files under NeoY's support directory;
- runtime PID, last exit code, and error status.

Desired state is reconciled when NeoY launches and after setup mutations.

## MCP federation

Configured HTTP MCP servers are discovered with JSON-RPC `tools/list`. Their text-returning tools are dynamically exposed through NeoY as:

```text
mcp.<server>.<tool>
```

Calls are forwarded with `tools/call`. Disabling/removing a server unregisters its namespaced tools. Binary/image payloads are intentionally not re-encoded through this path; those capabilities should use references or dedicated native/file flows.

A local MCP process can be started by the startup supervisor and then federated by URL, keeping process lifecycle separate from transport/tool discovery.

## NeoX important-event bridge

NeoY forwards only policy-enabled `blocked`, `failure`, and `completed` events to the already-paired NeoX MCP endpoint through one NeoX native tool, `event.notify`. NeoX presents the event as a local notification after normal notification authorization. This reuses existing pairing/LAN trust rather than adding a cloud push service.

## Compatibility and retirement

NeoY preserves the current `_mcp._tcp`, `_neoy._tcp`, port 9224 MCP endpoint, port 8686 handoff receiver, `POST /agent`, durable inbox, demo/capture, accessibility, and phone-media behavior.

Browser profiles, cookies, ChatGPT-specific UI automation, and one-off browser workflow glue are deliberately outside Core. Those belong in skills/plugins/federated MCPs.

The standalone Python handoff bridge and old Neox Tour app remain retired. Generic MacBridge responsibilities covered by native permissions, supervised processes, MCP federation, and NeoX event forwarding can be retired only after the signed installed-app E2E is verified; MacBridge-specific browser/UI glue is not migrated into NeoY.

## Validation boundary

Automated validation covers schema migration, parser/config behavior, NeoY macOS build/tests, and NeoX simulator compilation. Installed-app E2E validates the signed `/Applications/NeoY.app` MCP surface, process supervision, permission reporting, and federation on a real Mac.

Actual TCC grants and an end-to-end notification shown on a physical paired NeoX device remain inherently dependent on human approval/device availability; NeoY reports these states instead of claiming them.


## v2.2 Core runtime

NeoY v2.2 separates control, execution, and optional product capabilities:

```text
trusted agent
    |
    +-- neoy.setup -------- control plane
    +-- mac.exec ---------- shell / jobs / PTY
    +-- mac.fs ------------ filesystem
    +-- codex.threads ----- read-only local Codex history
    +-- node -------------- same Core contract on trusted NeoY peers

optional registry (default enabled)
    +-- accessibility/computer
    +-- demo/recording
    +-- capture tour
    +-- phone integration
    +-- public tunnel
```

The canonical Core tool-name set lives in one runtime definition and is reused
by remote-node invocation. Adding a future Core surface must not require adding
per-machine wrappers.

Core execution is implemented in Swift/Foundation/Darwin and does not depend on
PM2. PM2 remains the product deployment/keepalive supervisor for NeoY and the
Cloudflare tunnel. `runtime-control.sh` remains deployment/tunnel glue only.

### Public transport

The v2.1 public MCP endpoint stays usable for ChatGPT/plugin discovery of
non-privileged optional tools. Privileged Core tools and configured federated
MCP tools are hidden on untrusted/public requests. A trusted token can authorize
Core access; the token is generated locally and stored with mode `0600`.
