# Neo.app Harness and Neo Projects setup contract

This document describes Neo.app's integration with the installed Neo Harness
and the generic Agents Relay. The owning design principles remain in
[design-principles.md](design-principles.md); this page concerns installation
and configuration, not Relay's Job lifecycle.

## Responsibility

Neo.app owns the native app, MCP gateway, macOS privileges, user-facing
settings and managed Harness installation/update. It must not assume a Neo
source clone exists, store a second project repository, or implement the
Relay Task/Review state machine. Neo Harness supplies `neo` CLI, bootstrap,
shared Agents/Skills, project discovery and execution-context preparation.
Agents Relay is a standalone orchestrator invoked by the Harness.

## One setting in Neo.app: NEO_ROOT

The Projects root is presented as one user-visible directory field:
`NEO_ROOT`. Persistent JSON is `~/.config/neo/workspace.json`:

```json
{"schemaVersion": 1, "neoRoot": "/absolute/projects-parent"}
```

Precedence: explicit `NEO_ROOT` environment override > saved `neoRoot` >
`~/Workspace` default. A running app with an environment override should
explain that the effective CLI root can differ from the saved field. App
startup validates the saved directory and **does not move project files or
Runs**. Upgrade-time conversion of old `workspaceRoot`/`projectsRoot`
fields is one-time and preserves the effective old Project path; those fields
are not part of the new public configuration contract.

On Neo Master only, the configured value is `~/Workspace/neo`. On other Macs,
including fresh installs, the default remains `~/Workspace`.

## Managed installation

Neo.app should prepare the CLI and required shared Agents/Skills during
first-run setup and repair a missing managed CLI on startup. Harness assets
are resolved from the installed package path, not `NEO_ROOT`, the app repo or
a Neo source checkout. Source development symlinks must not be silently
replaced by a managed install. Independent projects live under their selected
root, each with its own `.git`; the app lists them via the Harness CLI rather
than a second hardcoded project enumeration.

**Current deployment limitation:** the managed CLI uses Node.js/npm and the
clean-source installer requires a local toolchain. A completely standalone
Neo.app package that provisions a runtime with zero prerequisites is not yet
verified. `@lalalic/neo@1.0.3` is the next pinned package; publishing it is a
release prerequisite, not an accomplished step.

## Generic Relay boundary

Neo.app may expose native, remote, browser and review providers to callers.
Relay owns durable Job/Task/Review identity, graph transitions and recovery;
no Neo.app process or `neo` executable should be mandatory for a non-Neo
Relay Job. A Relay provider may use the Neo MCP gateway, but that is an
optional integration, not a core dependency. Remaining hard-coded Neo
references are inventoried in the Relay source repository's
`docs/harness-independence.md`.

## Acceptance

- Fresh app setup prepares `neo` and shared Skills; users do not need a Neo
  source checkout (subject to the documented Node/npm prerequisite).
- App and CLI resolve the same `NEO_ROOT` and honor the environment override.
- Project discovery lists independent Git roots, not legacy `neo/<project>`
  aliases; a local-only repository works.
- Updating the app or Harness never moves or adds private `runs/` to Git.
- The installed package's Agent/Skill lookup works from outside the source
  checkout.
- Release requires verified read-back, tests and explicit owner approval;
  no CLI package publication, app install or migration is implied by docs.
