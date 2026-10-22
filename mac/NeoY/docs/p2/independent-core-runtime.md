# P2 — Independently managed Neo Core runtime

NeoY.app is the stable native control plane. The `@lalalic/neoy-core` npm package supplies its Core MCP runtime independently of app release cycles.

## Location and lifecycle

- Signed app Core at `NeoY.app/Contents/Resources/Runtime` is a **bootstrap/recovery seed only**.
- Active runtime is stored at `~/Library/Application Support/NeoY/runtimes/core/versions/<package-version>/`.
- `current` is an atomically replaced symlink to the active immutable version. `previous-version` records the last active version after successful upgrades.
- Native Core provider resolves the managed runtime first, falling back to the app seed only if `current` is absent or invalid; external MCP providers are unaffected.
- First launch copies the bundled seed into the versioned managed directory. No developer checkout is required.

## Updating without replacing NeoY.app

Open **NeoY Setup → Advanced → Runtime**. Enter a semver version, `latest`, or an absolute `.tgz` path for a verified local `@lalalic/neoy-core` npm package. Click **Upgrade Core**.

The installer creates an isolated temporary npm prefix with `--ignore-scripts`, requires the exact `@lalalic/neoy-core` identity and expected version, checks MCP initialization and `tools/list` using the candidate in isolation, and only then atomically activates it. The activated installed copy is probed again; failures restore the previous active runtime. NeoY reconnects the Core provider only, without replacing the signed app or restarting unrelated providers. **Rollback** switches to the previously active version. Existing version directories remain immutable.

The npm package is managed by the `lalalic/neox/mac/NeoY/Runtime` source and published as `@lalalic/neoy-core`. The public npm registry currently may be older than the app seed; automatic downgrade is blocked. Publish new Core versions separately from NeoY.app (the package version must advance). When npm credentials are unavailable, use a verified `.tgz` artifact; no registry publication is assumed.

## Verification and boundaries

- `ManagedCoreRuntimeTests`: seed, independent upgrade, real npm-tarball MCP handshake, reversible rollback and invalid candidate rejection.
- The Core probe only performs MCP `initialize` and `tools/list`; it never invokes tools.
- Managed Core does not replace `neo` CLI, which has its own release cycle; this P2 does not rename the app bundle ID or launchd label.
- A runtime upgrade changes Core functionality without a NeoY.app rebuild; an upgrade of the native macOS app itself remains a separate signed installer operation.
