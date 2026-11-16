# Neo Master shared Cloudflare tunnel

## Owner and routing

Neo.app is the only `cloudflared` connector owner on Neo Master. Its existing
named tunnel `neoy` remains the identity and the app keeps the generated
`~/Library/Application Support/NeoY/cloudflared.yml` configuration.

| Public hostname | Loopback origin |
| --- | --- |
| `neoy.qili2.com` | `127.0.0.1:6767` (Neo MCP) |
| `neo-origin.qili2.com` | `127.0.0.1:8769` (model gateway) |
| `compute.qili2.com` | `127.0.0.1:8798` (compute web gateway) |
| `agents.qili2.com` | `127.0.0.1:8787` (Relay Dashboard) |

`gpu.qili2.com` is retired: it must not be in Neo.app ingress or DNS.
The extra routes are configured via `additionalTunnelRoutes` in Neo.app's
private `deployment.json`; every route is a validated DNS name + loopback port.
The named-tunnel credentials are unchanged; never copy them into the repository.

## Architecture decision

This is deployment infrastructure owned by Neo.app's native lifecycle, not
Core Rust execution or a new MCP tool. The model, compute, and Relay services
retain their respective process owners, local ports, and authentication. The
existing public contracts are preserved; no extra MCP tool is exposed. The
former independent Cloudflare connectors must be disabled in their PM2 or
launchd owners, without stopping the local services.

Neo.app's tunnel identity is cached locally so app reconnection does not rely
on Cloudflare's management API. Changing the tunnel name/primary hostname
still requires authoritative Cloudflare DNS registration. DNS migration of
secondary hostnames is an explicit operator step, not an untracked app startup
side effect. Failed route changes must retain the old connector until verified.

Canonical architecture rules: [design-principles.md](design-principles.md).

## Verification and rollback

Validate the generated ingress with `cloudflared tunnel ingress validate`,
check the Cloudflare tunnel/DNS targets, and probe every public hostname before
disabling old connectors. Check that only one `cloudflared` process remains and
its parent is Neo.app. On failure, restore the prior DNS route and corresponding
old connector before rolling the app configuration back.
