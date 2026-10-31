# Neo Project lifecycle supervision

Neo.app supervises *selected* local Neo Projects using the project-owned executable `<project>/neo-project`; it does **not** own a separate Vlog daemon, scheduler, or MCP tool.

## Architecture decision

- **Native necessity:** Reconciliation at application startup and while the menu-bar host is running belongs to NeoY's device-local lifecycle. Domain behavior and durable project state remain in the project.
- **Existing owner:** The project's `neo-project` script owns setup, PM2/service startup, shutdown and health. NeoY only resolves the canonical project and invokes its advertised lifecycle verbs.
- **Intent / trust boundary:** A local owner-controlled `~/Library/Application Support/NeoY/projects.json` file is the desired-enabled list. Project names are validated; paths must resolve inside the user's Workspace and end in an executable `neo-project`. No additional public MCP method, port or authentication surface is created.
- **Lifecycle semantics:** `status.running`, `start` and `health` are service readiness, not proof that a phone submission has been processed or a Vlog created. The project's own inbox and Relay receipts supply downstream evidence.
- **Deployment:** NeoY invokes project verbs, never embeds PM2 internals or copies project package launchers into native code. Failure of one optional project is logged and does not block the gateway.

The file has the shape:

```json
{"enabled":["vlog"]}
```

With the file missing or `enabled:[]`, Neo.app does not activate any optional project. This prevents newly discovered projects from starting automatically. Setup and start occur only when a selected project is not running; `health` is checked every five minutes with bounded recovery. Disabling a project prevents future auto-recovery. To stop one, call its own `neo-project stop`; do not delete user media or `runs/`. Neo.app does not assert that a project is configured just because `neo project resolve` returns an entrypoint.

The Vlog project uses an iCloud Drive inbox to receive submissions from the Neo iOS app, including when the user is away from local Wi-Fi. The phone-side submission confirmation and the downstream Relay Job status must be verified independently of Watcher process health.
