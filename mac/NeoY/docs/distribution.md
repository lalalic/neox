# Neo macOS distribution (P0/P1)

Source owner: `lalalic/neox`, `mac/NeoY`. Product name is **Neo**. Preserve
bundle ID `com.neox.neoy`, the native launchd service, existing MCP names,
TCC grants, and on-disk user data during this release.

## Package ownership

| Artifact | Source owner | Public identity |
| --- | --- | --- |
| macOS GUI, gateway, native permissions | `lalalic/neox` | `Neo.app`, `com.neox.neoy` |
| Agent CLI, project/skill routes | `lalalic/neo` | `@lalalic/neo`, executable `neo` |
| Federated shell/fs/PTY provider | `lalalic/neox/mac/NeoY/Runtime` | `@lalalic/neoy-core` |
| Browser automation | `lalalic/browser-workspace` | WebHelm, independently managed |
| Durable agent tasks | `lalalic/agents-relay` | Agents Relay, independently managed |

The historical unscoped global npm package `neo` is **not** the canonical
CLI distribution. On an existing machine, Neo.app must detect that package
and report `migration_required`; it must never silently overwrite a binary
it does not own. Moving an existing installation to `@lalalic/neo` requires
an explicitly accepted migration, backup of the previous executable/package
identity, and tested rollback. Do not remove the legacy package in setup.

## Release workflow

The workflow `.github/workflows/neo-macos-release.yml` runs on an
`neo-v<VERSION>` tag, where VERSION must equal the native app's
`CFBundleShortVersionString`. It builds/tests, Developer-ID signs, notarizes
and staples a DMG, emits SHA-256, and creates a GitHub Release. Manual
`workflow_dispatch` builds the selected existing tag but does not publish.

Configure GitHub environment `macos-release` with:

- `NEO_DEVELOPER_ID_P12_BASE64`: base64 of exported Developer ID Application P12.
- `NEO_DEVELOPER_ID_P12_PASSWORD`: P12 password.
- `NEO_DEVELOPER_ID_IDENTITY`: exact `security find-identity` name.
- `NEO_APPLE_TEAM_ID`: Apple team identifier.
- `ASC_API_KEY`: App Store Connect API private key P8 content.
- `ASC_KEY_ID` and `ASC_ISSUER_ID`: matching key IDs.

Protect signing credentials in an approved release environment. Only trusted
tag writers may run the signing workflow. No P12/private keys belong in Git.
An Apple Development certificate cannot substitute for Developer ID.

## Release gates

1. CLI source identity and macOS package-owner collision tests pass.
2. The signed application contains the pinned Core runtime without requiring
   the developer's Git checkout.
3. On a clean Mac, mounting DMG and launching Neo completes with Gatekeeper
   under default settings; notarization and staple validation pass.
4. Repeat setup does not create duplicate services; a legacy `neo` binary is
   left intact and reports its migration requirement.
5. Existing Neo installations upgrade without loss of TCC identity or data.

P0/P1 source and workflow work is not evidence of gates 3-5. Those require
signed distribution credentials, fresh-install E2E, and migration testing.
Sparkle/Homebrew/automatic service upgrades belong to subsequent phases.
