# Neo Master shared Cloudflare tunnel — operations runbook

## Ownership and source of truth

**Neo.app owns the only `cloudflared` connector on Neo Master.** Do not create
another `cloudflared` process in PM2, launchd, a Project, or a shell. The named
Cloudflare tunnel is `neoy`. Services remain independently supervised; the
connector only routes requests. No separate Neo tunnel service is needed.

**Live editable configuration:**
`~/Library/Application Support/NeoY/cloudflared.yml` (private 0600 file).
Neo.app creates it if missing, then leaves edits untouched. Neo.app watches
its contents every second (including atomic file replacements), validates each
revision using `cloudflared tunnel ingress validate`, and automatically restarts
**only its own connector** after a valid change. If validation fails, it logs
the rejection and keeps the current connector running. Changing YAML does not
require building or restarting Neo.app. The file contains credentials *paths*,
never commit credentials or the live private file into Git.

| Public hostname | Loopback origin | Purpose |
| --- | --- | --- |
| `neoy.qili2.com` | `127.0.0.1:6767` | Authenticated Neo MCP |
| `models.qili2.com` | `127.0.0.1:8769` | Model gateway |
| `compute.qili2.com` | `127.0.0.1:8798` | Compute gateway |
| `agents.qili2.com` | `127.0.0.1:8787` | Relay Dashboard |

`gpu.qili2.com` is retired; never recreate its ingress or DNS record.
The existing application security/authentication policies remain responsible
for each service. A tunnel route does *not* confer authentication.

## Agent runbook: add / change / remove

1. **Read before changes.** Inspect this runbook, the live YAML, the target
   loopback service and its authentication. Verify the hostname belongs in the
   intended Cloudflare account/zone. Never expose a service without reviewing
   whether its existing auth is appropriate for public use. Do not edit the
   tunnel ID, credential path, or `neoy.qili2.com` primary origin casually.
2. **Backup and edit YAML atomically.** Keep existing routes and the terminal
   `- service: http_status:404`. To add a hostname, add `- hostname: NAME`
   and `service: http://127.0.0.1:PORT` above the fallback. To change a route,
   change only that `service:`. To remove, delete that route block. Preserve
   the other routes. Keep ownership/permissions private (0600).
3. **Validate.** Run
   `cloudflared tunnel --config "$HOME/Library/Application Support/NeoY/cloudflared.yml" ingress validate`.
   Neo.app also validates and reloads automatically on a valid changed file,
   even when the editor replaces it atomically. Do not manually restart the
   connector or Neo.app. Watch `cloudflared.pid` for the new connector PID.
   Invalid YAML is rejected without stopping the currently running connector.
4. **DNS is separate from YAML.** Adding a new public hostname requires a
   Cloudflare DNS CNAME to the existing `neoy` tunnel. After checking that no
   conflicting DNS entry exists, use
   `cloudflared tunnel route dns neoy NAME` (or the Cloudflare DNS API).
   If a name already points to this tunnel, no DNS change is necessary.
   Changing only an origin port does not require a DNS change. Removing an
   unused public name requires deleting **only its own** Cloudflare DNS record
   after verifying that it points to the expected tunnel; don't remove a name
   owned by another service. Never overwrite a conflicting DNS record blindly.
5. **Verify.** Probe the intended public service, authentication (including
   unauthorized access), and the remaining public hosts. Confirm one live
   `cloudflared` child with Neo.app as parent. If a cutover fails, revert the
   YAML from backup (Neo.app will auto-reload) and restore the verified DNS
   record if one was changed.

Cloudflare tunnel routes are application HTTP ingress. Tunnel changes do not
start, stop, or deploy the upstream service. Prefer loopback origins, not
public or LAN origins. Avoid exposing internal dashboards or privileged services
without a separate verified authentication/authorization layer.

## Architecture decision

This is Neo.app native *deployment lifecycle*, not a Core Rust execution
capability or a new MCP tool. The existing service owners remain authoritative.
No new external MCP surface or separate public trust boundary is created.
Neo.app's tunnel identity is cached locally so connector restart does not
depend on Cloudflare's management API. DNS edits remain deliberate operations,
not automatic side effects of editing YAML.

Canonical architecture principles: [design-principles.md](design-principles.md).
