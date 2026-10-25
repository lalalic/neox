# Clean Mac install and ChatGPT connection

This repository currently builds the NeoY menu-bar service and installs it as
`/Applications/Neo.app`. It does not contain a `Leo.app` target or a downloadable
Leo/Neo release. The supported clean-user path is to clone this repository and
run its local installer; do not use an unverified download link.

## Prerequisites

- macOS 14 or newer.
- Xcode 16 with command-line build tools, XcodeGen, Node.js 18 or newer, and npm
  available on `PATH`.
- A valid Apple Development code-signing identity in the login keychain. Check
  with `security find-identity -v -p codesigning`.
- A local Codex session on the Mac where Neo will run.
- A ChatGPT web workspace/account that is permitted to create custom MCP
  connections. Full MCP tool access is currently limited by OpenAI plan and
  workspace permissions; an administrator may need to grant creation rights.

The installer runs the NeoY Core runtime tests, generates and builds the Xcode
project, signs the app, installs `/Applications/Neo.app`, and registers its
per-user launch agent. NeoY starts Core and performs best-effort setup of its
pinned Neo CLI and only its missing global skills. Existing Neo CLI development
links and already-installed skills are retained. The installer is for a clean
install or an intentional NeoY upgrade; inspect it before using it on a Mac
that already runs NeoY or legacy services.

## Copyable instruction for local Codex

Paste this into Codex on the intended Mac, then complete the approval handoffs
it identifies:

```text
Install and connect the canonical NeoY service from https://github.com/lalalic/neox.git on this Mac.

First confirm this is the Mac I intended, inspect the repository's AGENTS.md, mac/NeoY/README.md, mac/NeoY/docs/design-principles.md, and mac/NeoY/install-local.sh, then check the prerequisites listed in mac/NeoY/docs/clean-user-install.md. This is the Neo.app source-build workflow; there is no Leo.app download in this repository. Do not substitute another installer or artifact.

If ~/Workspace/neox already exists, verify its origin and working tree before using it; do not overwrite local work. If it does not exist, clone the canonical repository there. If any prerequisite is missing, an existing Neo/NeoY app or service is present, or the installer would affect unrelated user state, stop and explain the exact issue before changing anything. Otherwise run mac/NeoY/install-local.sh directly once from the verified checkout. Do not wrap it in a supervisor or retry loop.

After installation, verify the app bundle, launch agent, and local MCP status without printing or sending secrets. Open Neo's Setup window. In Remote, enable remote MCP only for the ChatGPT connection, select only the capabilities needed for this task, start the temporary tunnel (or use my already-configured hostname), and test the remote endpoint. In MCP, read the endpoint, client ID, and token locally; never put the token in this Codex prompt, terminal output, a file, or a ChatGPT message.

In ChatGPT web, create a private custom MCP connection named neo using Neo's remote /mcp endpoint and OAuth. Do not publish it to a workspace. Stop when ChatGPT sign-in, workspace-admin permission, or the Neo OAuth approval page needs me. I will enter the Neo token only into Neo's local OAuth approval page and approve the connection there. Then verify the connector is enabled and can list its tools. Report each observed check and any remaining blocker; do not claim success from a screenshot alone.
```

## Expected observations

1. `install-local.sh` prints `Installed /Applications/Neo.app; startup mode: launch-agent-keepalive` and a code-signing requirement. It exits before building if XcodeGen, Xcode, Node/npm, Node 18+, or a signing identity is missing.
2. Neo appears in the menu bar. Open **Setup…** from its menu. The **MCP** tab shows the local endpoint, client ID, and secret token; **Test local** should pass.
3. In **Remote**, enable the temporary tunnel or configured hostname, select the minimum required remote capabilities, and wait until the remote endpoint appears. **Test remote** should pass. Temporary Cloudflare addresses can change after a restart.
4. In ChatGPT web, create a private custom MCP connection named `neo` with the remote `https://<host>/mcp` endpoint and OAuth. ChatGPT discovers OAuth metadata from NeoY. During sign-in, the browser opens NeoY's **Authorize Neo** page. Enter the token in that page and approve; OAuth then returns to ChatGPT. The token is not the OAuth client ID and must not be pasted into a chat or prompt.
5. The `neo` connection appears enabled in ChatGPT Apps, and ChatGPT can scan its tools. Keep the connection private; do not publish it to the workspace.

OpenAI currently documents custom MCP connections through ChatGPT Apps and
workspace permissions; the exact navigation and plan availability can change.
See [Connecting custom MCP servers in ChatGPT](https://help.openai.com/en/articles/12584461-connecting-custom-mcp-servers-in-chatgpt)
for the current eligibility and creation flow.

## Recovery

- **Prerequisite error:** install or select the named toolchain, confirm
  `node --version` is at least 18, and confirm the signing identity with
  `security find-identity -v -p codesigning`. Re-run the installer only after
  correcting the missing prerequisite.
- **Build or installer failure:** keep the exact error; inspect
  `mac/NeoY/build/` and the installer output. Do not manually replace the app or
  restart NeoY. The installer stages a candidate and uses its watchdog to
  restore the previous app if post-install health checks fail.
- **App or local MCP is unavailable:** open **Setup… → MCP → Test local**; check
  `launchctl print gui/$(id -u)/com.neox.neoy.keepalive` and
  `~/.neoy/launchd.err.log`.
- **Remote test fails:** in **Setup… → Remote**, inspect the tunnel status and
  endpoint. For temporary addresses, use the current endpoint rather than a
  stale ChatGPT connection URL. A custom stable hostname requires the user's
  Cloudflare configuration.
- **ChatGPT cannot create or scan the connection:** check the workspace's MCP
  connection permissions and plan eligibility. Ask the workspace admin for
  access; do not publish the connection as a workaround.
- **OAuth fails:** restart authorization from ChatGPT, verify the current
  client ID and remote endpoint in **Setup… → MCP/Remote**, and enter the current
  Neo token only on the NeoY approval page. Use **Revoke token** only if the
  token was exposed; it invalidates existing approvals.

ChatGPT login, workspace administration, and the Neo OAuth approval are explicit
human handoffs. NeoY remains the authenticated public gateway and MCP capability
host; the installer does not add a second externally reachable authority.
