# NeoY Core ownership matrix

NeoY preserves the needed developer capabilities by bundling and federating
upstream MacBridge. It does not copy MacBridge capabilities into Swift.

| Capability | Owner and public contract |
|---|---|
| Shell execution | bundled MacBridge: `shell_exec` |
| Background jobs | bundled MacBridge: `shell_start`, `shell_job_status`, `shell_job_list`, `shell_job_kill` |
| Filesystem | bundled MacBridge: `fs_read`, `fs_write`, `fs_list`, `fs_stat`, `fs_manage` |
| PTY | bundled MacBridge: `pty_start`, `pty_read`, `pty_write`, `pty_resize`, `pty_signal`, `pty_close` |
| Codex history | bundled MacBridge: `codex_thread_read`, `codex_thread_list`, `codex_thread_turns_list` |
| Patch application | bundled MacBridge: `apply_patch` |
| Cluster routing/control | NeoY-owned `cluster` facade and node transport adapters |
| Auth, remote exposure, federation, lifecycle, native/TCC features | NeoY-owned |

MacBridge discovery failure is isolated: NeoY still starts with its native
surface and reports the provider as unavailable. Protected remote exposure is
filtered by NeoY feature authorization; the provider does not create a second
Internet-facing trust boundary.
