# NeoY Core ownership matrix

NeoY preserves the needed developer capabilities in `@lalalic/neo` Core tools.
The implementation was migrated from MacBridge source; MacBridge is no longer a
runtime dependency, and NeoY does not duplicate these capabilities in Swift.

| Capability | Owner and public contract |
|---|---|
| Shell execution | Core facade: `shell` (`exec` subcommand) |
| Background jobs | Core tools: `shell_start`, `shell_job_status`, `shell_job_list`, `shell_job_kill` |
| Filesystem | Core facade: `fs` (`read` / `write` / `list` / `stat` / `manage`) |
| PTY | Core facade: `terminal` (`start` / `read` / `write` / `resize` / `signal` / `close`) |
| Codex history | Core facade: `codex` (`thread.read` / `thread.list` / `thread.turns.list`) |
| Patch application | Core tools: `apply_patch` |
| Cluster routing/control | NeoY-owned `cluster` facade and node transport adapters |
| Auth, remote exposure, federation, lifecycle, native/TCC features | NeoY-owned |

Core-tools startup failure is isolated: NeoY still starts with its native
surface and reports the Core provider as unavailable. Protected remote exposure is
filtered by NeoY feature authorization; the provider does not create a second
Internet-facing trust boundary.
