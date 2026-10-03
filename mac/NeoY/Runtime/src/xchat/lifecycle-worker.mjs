import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

const [action, configPath, statusPath] = process.argv.slice(2);
if (!["new-turn", "new-thread"].includes(action) || !configPath || !statusPath) process.exit(64);

const cli = process.env.BROWSER_WORKSPACE_CLI
  || path.join(os.homedir(), ".agents/skills/browser-workspace/bin/browser-workspace");

function writeStatus(payload) {
  const tmp = `${statusPath}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, JSON.stringify(payload), { mode: 0o600 });
  fs.renameSync(tmp, statusPath);
}

const started = new Date().toISOString();
try {
  writeStatus({ transfer_id: path.basename(statusPath, ".status.json"), status: "running", mode: action, started_at: started });
  const result = spawnSync(cli, ["platform", "run", "chatgpt", action, "--config", configPath], {
    encoding: "utf8",
    timeout: Number(process.env.XCHAT_LIFECYCLE_TIMEOUT_MS || 600_000),
    maxBuffer: 4 * 1024 * 1024,
  });
  const stdout = String(result.stdout || "").trim();
  const stderr = String(result.stderr || "").trim();
  if (result.error || result.status !== 0) {
    writeStatus({
      status: "failed",
      mode: action,
      started_at: started,
      finished_at: new Date().toISOString(),
      exit_code: result.status,
      error: result.error?.message || stderr || stdout || "Browser Workspace lifecycle action failed",
    });
    process.exitCode = result.status || 1;
  } else {
    let output = stdout;
    try { output = JSON.parse(stdout || "{}"); } catch {}
    writeStatus({
      status: "completed",
      mode: action,
      started_at: started,
      finished_at: new Date().toISOString(),
      output,
    });
  }
} finally {
  try { fs.unlinkSync(configPath); } catch {}
}
