# NeoY local deployment contract

UI review lesson: Remote MCP address selection is only a draft until explicit
Apply. Changing exposure permissions must never save a pending address or mode.
Keep optional toolkit installation separate from mandatory bootstrap skills.
Feature UI must preserve the published-package catalog; native MCP toggles use
the existing control-plane capability owner, not the remote exposure allowlist.

Native Accessibility presses that trigger SwiftUI button actions must execute on
the main actor; off-main AXPress can crash Neo.app.

PR merge is **not** completion for a NeoY change that must be applied locally.
Choose the deployment path by what changed; do not rebuild/reinstall the native app
for a Runtime-only change.

**Runtime-only path** — use this when the change is confined to
`mac/NeoY/Runtime/**` and does not change Swift, app resources, entitlements,
launchd/install configuration, signing, or the native app bundle:

1. Fast-forward the canonical local checkout to merged `origin/main`.
2. Do **not** run `mac/NeoY/install-local.sh`. Package the changed Core Runtime
   with a version newer than the active managed release, then use Neo setup's
   `core upgrade <absolute-tgz-path>` for probe, activation, and provider reconnect.
3. Verify the activated Core version, provider readiness, and MCP behavior.
   Do not restart the Neo app for a Runtime-only change.

**Native-app path** — use this when Swift, UI, app resources, entitlements,
permissions, launch behavior, installer/launchd configuration, signing, or the
application bundle changes:

1. Fast-forward the canonical local checkout to merged `origin/main`.
2. Run `mac/NeoY/install-local.sh` **directly, exactly once**, from that canonical
   checkout. The script already performs tests, build, signing, staging, backup,
   app replacement, launchd restart, health verification, and rollback protection.
3. Never wrap `install-local.sh` in `launchctl submit`, a KeepAlive job, PM2, cron,
   a retry loop, or any other supervisor/background job that may re-run it. A
   supervised installer repeatedly stops/replaces/restarts NeoY and causes a
   start/stop loop.
4. Do not bypass the installer with ad-hoc `killall`, direct app copying, Xcode Run,
   or a different signing identity. `upgrade-watchdog.sh` is an internal rollback
   helper used by `install-local.sh`; it is not a manual restart command.
5. Verify the installed NeoY is healthy after deployment, including MCP
   connectivity and any task-relevant UI/runtime behavior. Treat rollback or failed
   post-deploy health verification as deployment failure.

The orchestrator should perform the appropriate path itself; the user should not
need to separately ask to apply or restart NeoY after a Job finishes.
`/Applications/Neo.app` remains the single macOS permission identity (bundle ID
`com.neox.neoy`).
