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
entry and validates sudoers with `visudo`. On macOS installations without a
sudoers include, it adds only `#include /private/etc/sudoers.d/com.neox.neoy.helper`
to the root sudoers file, preserving the original for rollback. It verifies
passwordless access as the actual target user before returning success.

- `/Library/PrivilegedHelperTools/com.neox.neoy.helper` (root:wheel, 0755)
- `/private/etc/sudoers.d/com.neox.neoy.helper` (root:wheel, 0440)

Check through `neoy.setup privilege status`. A passwordless local CLI test is
`sudo -n -k /Library/PrivilegedHelperTools/com.neox.neoy.helper check dns.flush`.
To revoke, use an interactive administrator shell to remove the exact
`#include /private/etc/sudoers.d/com.neox.neoy.helper` line from
`/private/etc/sudoers` (if Neo added it), validate with `visudo -c`, then
remove the included policy file and optionally the helper. Never remove the
included policy while leaving a dangling `#include` reference in sudoers.
Removing the app alone does not revoke the separate authorization. Never
store an administrator password or configure `NOPASSWD: ALL`.
