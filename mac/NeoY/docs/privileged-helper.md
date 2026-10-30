# NeoY Privileged Helper

## Architecture Lens (`docs/design-principles.md`)

- **Native necessity / existing owner:** root-only system maintenance is a macOS
  authorization concern. Generic shell execution remains with Core, running as
  the macOS user. NeoY provisions a separate signed, root-owned executable.
- **Intent / public surface:** the existing `setup` facade accepts `privilege
  status` and `privilege run <approved-action>`. No generic root shell, new MCP
  tool, root-accessible socket, XPC service or user-provided shell string.
- **Trust:** NeoY keeps its normal MCP authentication. macOS sudoers permits
  only this root-owned, non-user-writable executable; the helper independently
  rejects all unapproved argument combinations. Sudo's `-n` forbids prompts.
- **Lifecycle:** a successful operation reports completion only after the
  subprocess exits zero. Admin setup is a separate, one-time OS authorization.
  Auto-upgrades must not silently replace the root-owned binary or policy.
- **Deployment:** native signed-app installer handles provisioning; no PM2
  dependency, user-level daemon, untrusted install package, or duplicate Core.

## Frozen actions

- `dns.flush` — clear system DNS cache and signal mDNSResponder.
- `vpn.server.status`, `vpn.routing.status` — inspect only system launchd
  labels `io.macikev2.server` and `io.macikev2.routing`.
- `vpn.server.restart`, `vpn.routing.restart` — kickstart only those two
  **already loaded** system launchd labels (will not enable disabled jobs).

All other actions are rejected. New actions require source code review, signing
and explicit administrator installation; they cannot be configured by agents.
Every executed action and denial is reported to macOS Unified Logging.

## Installation and revocation

`install-local.sh` compiles the helper, signs it using the same Apple
Development identity as NeoY, and requests a macOS administrator approval once
if the root-owned helper is missing or has changed. The root installer verifies
its signed developer team, owner and permissions, creates the exact sudoers
entry and validates sudoers with `visudo`. macOS already includes
`/private/etc/sudoers.d`; its directory scanner skips names containing a
period. The policy filename therefore has **no dots**. Installation never
modifies `/private/etc/sudoers`. It verifies passwordless access as the actual
target user before returning success.

- `/Library/PrivilegedHelperTools/com.neox.neoy.helper` (root:wheel, 0755)
- `/private/etc/sudoers.d/neoy-privileged-helper` (root:wheel, 0440)

Check through `neoy.setup privilege status`. A passwordless local CLI test is
`sudo -n -k /Library/PrivilegedHelperTools/com.neox.neoy.helper check dns.flush`.
To revoke, use an interactive administrator shell to remove
`/private/etc/sudoers.d/neoy-privileged-helper`, then optionally remove the
root-owned helper. Removing the app alone does not revoke this separate
permission. Never store an administrator password or configure `NOPASSWD: ALL`.

## Agent usage and discovery

Agents use ordinary shell commands: `neo privilege list`, `neo privilege status`,
and `neo privilege run dns.flush`. The root helper, not the CLI, enforces the
fixed action allowlist. On failed sudo authentication, the Core shell returns
a discovery hint directing the agent to this CLI without retrying the original
command or accepting an administrator password. NeoY's setup privilege route
remains a compatibility/diagnostic API; it does not own day-to-day execution.
