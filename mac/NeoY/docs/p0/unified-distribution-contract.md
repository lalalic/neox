# Neo Unified Distribution — P0 release contract

Status: P0 design and source inspection; **NOT a shipped installer**. Owner: `lalalic/neox` product control plane. Source owners remain separate.

## Architecture lens

The native app is necessary for signed host identity, TCC permissions, OAuth/MCP gateway and local lifecycle. Core shell/fs/PTY do not need Swift or native TCC. Relay owns durable jobs, Browser Workspace owns browser sessions, and the Neo source repo owns its existing scripts. Public CLI expresses user intent; it delegates to version-pinned implementers. CLI dispatch does not imply an additional public MCP tool. An installer launch or queued operation is not proof of final completion.

## Immutable bill of materials (BOM) and provenance

| Product | Source authority | Observed version | Release required proof | State |
|---|---|---|---|---|
| Native NeoY/Neo app | `neox/mac/NeoY` + Xcode project | 2.3.1 (earlier live observation) | signed bundle ID, code-sign team, git SHA, artifact SHA-256, macOS min version | NOT_VERIFIED for release |
| Core Node provider | `neox/mac/NeoY/Runtime/package.json` | `@lalalic/neo@0.1.7` | npm integrity + tarball hash + lockfile + Node compatibility + bundle resource verification | NOT_VERIFIED |
| Core runtime identity | `CoreRuntime.swift` | independent app/runtime field, not package SemVer | published API/schema revision and provenance link | NOT_VERIFIED |
| Historical Neo CLI | `neo/package.json` | `neo@1.0.1`; bins `neo`, `neo-queue` | frozen tarball + bin behavior golden fixtures | NOT_VERIFIED |
| Relay | `agents-relay` owner, separately supervised | runtime-selected `@latest` historically | exact pinned package/integrity + SQLite schema + migration/rollback | NOT_VERIFIED |
| Browser Workspace | external runtime owner | not pinned | owner URL, version, launcher, profile storage + consent | NOT_VERIFIED |
| Events/NATS | separate services | not pinned | separate signed/pinned binaries, ports, ownership | NOT_VERIFIED |

**Release BOM format**: `{component, owner, source_repository, source_sha, version, artifact_uri, sha256, integrity, platform, architecture, node_range, api_schema_version, dependency_constraints, permissions, data_paths, rollback_artifact}`. Missing mandatory values must make publication fail, not become `latest` implicitly.

## Core packaging and launch contract (P0-01)

1. Produce a deterministic npm pack of `mac/NeoY/Runtime` at a pinned git ref. Verify `src/core/tools/index.mjs`, its imports and package metadata. Record SHA-256 and registry integrity. P0 has two byte-identical npm tarballs (17 files); the unsigned candidate is NOT a released artifact.
2. **Implemented P0 packaging path:** `project.yml` copies Runtime as a folder reference into signed app `Contents/Resources/Runtime`, and `NeoYBundledRuntime.packagedRuntimeURL` resolves only that bundled location. Its version is pinned by the signed app artifact and BOM; the native app installer stages/replaces/rolls back the whole bundle. Do **not** use `~/Workspace/neox` as a runtime default. Runtime does not require the source checkout. Node remains an external `>=18` prerequisite requiring P1 installer discovery/version enforcement; absent Node is `needs_configuration`.
3. Native Core resolver uses the app-bundled Runtime only. A missing entrypoint yields no Core provider and must not prevent the native gateway launching. Production should report precise `not_installed`/`failed`/`needs_authorization`; exact user-facing state classification remains P2 NOT_VERIFIED. No checkout fallback.
4. Spawn Core as a separate stdio process. Health means MCP initialization plus `tools/list`, not just fork success. Restart Core without restarting the native app. Do not launch parallel copies.
5. Upgrade stages a signed new app bundle and checks Core compatibility + health. The existing native installer has rollback watchdog semantics; installed update/rollback has NOT been executed under this P0 instruction. Keep previous app executable/config and preserve user data, credentials and SQLite. Independent Core process restarts are separate from full native app installs.
6. The former `repoRuntimeURL` default is removed in branch `feat/neo-p0-unified-distribution`. Local unsigned native build and Core MCP source-free fixture **PASS**. Fresh signed installation, managed Node provision, codesign and real app rollback remain **NOT_RUN**.

## CLI namespace and migration (P0-02, H)

- `neo` public namespace is owned by the signed Neo product; implementation of escalation/project/skill/queue/package/updater stays with `lalalic/neo` and service owners.
- Existing unscoped `neo@1.0.1` already exposes `neo` and `neo-queue`. No silent PATH replacement. Installer must detect command, owner and symlink target and report conflicts; propose an explicit opt-in swap with atomic rollback to prior executable.
- Compatibility mapping: `neo escalation` -> prior implementation; `neo queue` -> `neo-queue`; `neo project resolve/list` -> `list-xchat-projects`; `neo skill list/package` -> `list-xchat-skills` / ChatGPT ZIP packager. These are planned routes, not currently available commands.
- Legacy absolute XChat scripts continue working for developer checkouts during transition. Packaged XChat bootstrap cannot contain a fixed `/Users/chengli` path. Golden tests must compare output schema, stderr, and exit codes before deprecating legacy entrypoints.
- Rename display name before changing signed bundle identifier. Preserve `com.neox.neoy`, launch agent IDs, MCP tool names, Core data under Application Support/NeoY and TCC identity until an independently verified dual-read/single-write reversible migration. Never rewrite durable Relay event IDs.

## Permission policy (P0-05)

Default install: no shell full-access acknowledgment, no unattended escalation, no broad filesystem grant, no accessibility/screen-recording/microphone/Photos permission assumption, no automatic public tunnel, no remote pairing, no external credential copy. Each capability reports `needs_authorization` with an explicit user action, scope, revocation and audit record. The former unconditional `NEO_CORE_FULL_ACCESS_ACK` injection is removed from `BundledRuntime.swift`; `ProcessEnvironment.swift` also strips ambient inherited acknowledgment. Core now refuses to launch without explicit unlock (exit 78 in isolated smoke test). A user-facing scoped consent UX and precise status still require P2, so no default `ready` is claimed. Store secrets in an OS-protected credential store; never place secrets in manifests, log output, launch args, app package or paired node payloads. Opt-in scope must be revocable.

## Service/capability ownership and dependency matrix

| Capability | Implementation owner | Depends on | Permission/auth | State/health oracle | Lifecycle/data |
|---|---|---|---|---|---|
| Native gateway/setup/TCC | neox Swift | signed app, launchd | local consent, TCC | bound listener and authenticated MCP | Neo; Application Support/NeoY |
| Core shell/fs/PTY/Codex/patch | @lalalic/neo scoped Core | Node + pinned runtime | scoped filesystem/process consent | stdio initialize + tools/list | Native supervisor; Core data/log dirs |
| Shared projects/skills resolver | neo repo | installed skill pack + workspace | filesystem access | resolver exit JSON and fixture tests | Neo dispatcher; user workspace |
| Escalation | neo repo | Codex/provider credentials | explicit elevated approval | structured terminal result | owning CLI; logs and handoff |
| Queue/packager/updater | neo repo | package tools, service owner | distinct service privileges | CLI checks + service health | independent process; owner-defined data |
| Agents Relay | agents-relay | SQLite, auth, worker/router | GitHub/provider auth | durable job read + reconciliation | Relay service; SQLite retained |
| Events | events-bus + NATS | loopback transport | token/localhost policy | correlated publish/read | standalone services; event store |
| Browser Workspace | external browser owner | Chrome/session daemon | browser sign-in, profile opt-in | platform validate/session status | separate service; profiles preserved |
| Computer use/demo/capture | native NeoY | macOS TCC | Accessibility/Screen Recording | permission-specific E2E | native host; captured files |
| Remote nodes/phone | native + node runtime | paired network/node | explicit trust/pairing | verified node heartbeat/reconnect | node service; no secret propagation |
| Voice | optional provider | mic/speech services | microphone/provider auth | speech + response E2E | optional isolated service |
| HomeKit/Roku | adapter/device owner | LAN/device | HomeKit pairing, local network | read/write separately verified | optional adapters |
| family-tutor | @lalalic/family-tutor | federated MCP | provider-specific | initialize + tools/list | independent provider |
| Markcut/vlog | owning project skills | media pipeline | media/output authorization | preview and approval evidence | project workflow, not Core |
| Public tunnel | tunnel provider | network/tunnel daemon | **explicit public exposure consent** | endpoint auth and reachability | independent connector |

Every capability must carry owner, source, exact artifact/hash, OS/CPU, dependency/version constraints, data path, secret handling, opt-in, start/stop/health, update, rollback, uninstall retention. Status values: `not_installed`, `installed`, `needs_configuration`, `needs_authorization`, `ready`, `degraded`, `unsupported`, `failed`; optional deliberately stopped is not failed.

## Phased release gates

P0 = architecture/identity/packaging/consumer audits and executable contracts. P1 = staged installer and packaged Core without checkout; P2 = permission/manifest registry and status; P3 = service isolation, upgrades/rollback; P4 = public rename/CLI alias; P5 = multi-node qualification. **No phase claims release readiness by satisfying a paper contract alone.** P0 design gates can pass while implementation release gates remain blocked.

| Verification | Result | Required proof |
|---|---|---|
| Source/package identity | PASS (source inspection) | package.json and Swift resolver evidence |
| Native/CLI collision resolved in contract | PASS (design) | this file + existing P0 plan H |
| Checkout-free unsigned bundled Core | PASS (build + isolated stdio initialize/tools/list) | signed fresh host remains NOT_RUN |
| Fail-closed full-access default | PASS (source + native env test + isolated exit 78) | explicit consent UX NOT_VERIFIED |
| Legacy CLI golden fixtures | PASS (8 CLI fixtures) | new public Neo CLI comparison NOT_RUN (not implemented until P4) |
| New Mac install, repeat setup | NOT_RUN | installer logs and process counts |
| Version-pinned package upgrade and rollback | NOT_RUN | failed update injection / data retention |
| Native build and selected regression | PASS (build + SetupServiceTests 33/33) | full suite and signed install NOT_RUN |
| Node/Relay/MCP failure isolation | NOT_RUN | real-process fault injection |
| Core auth-negative | PASS (exit 78 without unlock) | native macOS TCC permission dialogs NOT_RUN |

Release P0 is **NOT PASSED** while blockers remain. No installation, restart, merge, push or live operation is authorized by this contract.

## 2026-10-22 executable evidence

- Source-backed inventory: `inventory-snapshot.json` (23 capabilities, 27 selected skills, 10 PM2 processes; one optional watcher stopped). Rebuild with `python3 p0_inventory.py --output inventory-snapshot.json`. This is local observation, not a release manifest.
- CLI source caller cross-reference: `xchat-consumers.md` (66 textual source hits, including documentation and tests). Search hits are not proof of active consumers.
- BOM candidate: `bom-candidate.json` (five package/source identities, Core tarball checksum/npm integrity, 26-file source-to-app-resource byte-for-byte match excluding four local `.DS_Store` files, native unsigned build checksum). It explicitly reports `release_ready=false`.
- `npm test` for Core Runtime: 33/33 PASS; legacy `neo` npm tests: 26/26 PASS; legacy XChat resolver unit tests: 4/4 PASS.
- P0 Python contract and CLI golden fixtures: 16/16 PASS with candidate built app path; Xcode native `SetupServiceTests`: 33/33 PASS; native build PASS; Core `tools/list`: 7 tools after test-only explicit unlock; without unlock exit 78. No tool/call or production action performed.
- Architecture review: native app still owns signed MCP/federation and TCC, Core remains independent stdio provider, Relay/Browser retain own services. No new MCP tools or processes/supervisors were introduced. App bundle includes Core resources; no runtime Git checkout remains.
- Outstanding: source-free *signed* clean install, CLI collision upgrade migration, end-user permission UX, real service recovery/rollback/multi-node, package dependency provisioning and independent external reviewer are NOT_VERIFIED/NOT_RUN.

## 2026-10-22 full-suite review/fix iteration

- Initial **full native test suite** exposed seven federation failures (76 total) after the fail-closed default change. Existing fake Core tests implicitly relied on production's unconditional full-access acknowledgement. This is a test-fixture defect, not grounds to restore insecure production defaults.
- `Tests/NeoYTests/MCPFederationTests.swift` now passes an explicit synthetic acknowledgement **only to tests that check Core authorization**. The automatic recovery fixture sets `requireCoreAuthorization: false`, because its purpose is restart/reconnection, not the Core security gate. The negative unauthorized case still runs with no acknowledgement.
- Re-run complete `xcodebuild ... CODE_SIGNING_ALLOWED=NO test`: **76/76 PASS**. No running services, signed applications or persisted user data were touched. This verifies unit/integration tests only; actual signed app installation and service recovery remain NOT_RUN.
- Independent external Reviewer: **NOT_RUN** (no independent reviewer worker was launched). Local source/diff review checked owner boundaries, environment stripping and fixture-only elevated authorization.
