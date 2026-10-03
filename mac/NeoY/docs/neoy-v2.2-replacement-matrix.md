# NeoY Core ownership matrix

NeoY preserves the needed developer capabilities in `@lalalic/neo` Core tools.
The implementation was migrated from MacBridge source; MacBridge is no longer a
runtime dependency, and NeoY does not duplicate these capabilities in Swift.

| Capability | Owner and public contract |
|---|---|
| Shell execution | Core tools: `shell_exec` |
| Background jobs | Core tools: `shell_start`, `shell_job_status`, `shell_job_list`, `shell_job_kill` |
| Filesystem | Core tools: `fs_read`, `fs_write`, `fs_list`, `fs_stat`, `fs_manage` |
| PTY | Core tools: `pty_start`, `pty_read`, `pty_write`, `pty_resize`, `pty_signal`, `pty_close` |
| Codex history | Core tools: `codex_thread_read`, `codex_thread_list`, `codex_thread_turns_list` |
| Patch application | Core tools: `apply_patch` |
| Cluster routing/control | NeoY-owned `cluster` facade and node transport adapters |
| Auth, remote exposure, federation, lifecycle, native/TCC features | NeoY-owned |

Core-tools startup failure is isolated: NeoY still starts with its native
surface and reports the Core provider as unavailable. Protected remote exposure is
filtered by NeoY feature authorization; the provider does not create a second
Internet-facing trust boundary.
