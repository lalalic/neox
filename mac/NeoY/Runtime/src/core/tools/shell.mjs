import os from "node:os";
const SHELL_EXEC_DEFAULT_TIMEOUT_MS = 600_000;
const SHELL_PROMOTION_MS = 300_000;
const SHELL_INLINE_BYTES = 16_384;

export const SHELL_TOOLS = [
{
    name: "shell_exec",
    title: "Execute shell command",
    description: "Run an arbitrary command through the configured login shell with the full permissions of the macOS user running this bridge. Use for commands that finish within the requested timeout. This can read, modify, delete, deploy, access the network, or invoke other programs.",
    inputSchema: {
      type: "object",
      properties: {
        command: { type: "string", minLength: 1, description: "Exact shell command to execute." },
        cwd: { type: "string", description: "Working directory. Supports absolute paths, relative paths, and ~/ paths. Defaults to the user's home directory." },
        env: { type: "object", additionalProperties: { type: ["string", "number", "boolean", "null"] }, description: "Environment overrides. Set a value to null to remove it." },
        stdin: { type: "string", description: "Optional text to send to stdin." },
        timeout: { type: "integer", minimum: 0, maximum: 1_800_000, default: 600000, description: "Maximum synchronous wait in milliseconds. If still running, returns status=running and a jobId without stopping the process. 0 returns the job immediately." },
        max_output_bytes: { type: "integer", minimum: 0, maximum: 64000000, description: "Inline output budget (default 16 KiB); larger output is saved to a system temporary file." },
      },
      required: ["command"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, idempotentHint: false, openWorldHint: true },
  },
{
    name: "shell_start",
    title: "Start background shell job",
    description: "Start an arbitrary detached background command with full host permissions. Output is written to persistent log files and the job can be inspected or stopped later.",
    inputSchema: {
      type: "object",
      properties: {
        command: { type: "string", minLength: 1 },
        cwd: { type: "string" },
        env: { type: "object", additionalProperties: { type: ["string", "number", "boolean", "null"] } },
        label: { type: "string", maxLength: 100 },
      },
      required: ["command"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, idempotentHint: false, openWorldHint: true },
  },
{
    name: "shell_job_status",
    title: "Inspect background job",
    description: "Check whether a background job is running and return the tail of its stdout and stderr logs.",
    inputSchema: {
      type: "object",
      properties: {
        job_id: { type: "string" },
        max_log_bytes: { type: "integer", minimum: 1024, maximum: 8000000, default: 100000 },
      },
      required: ["job_id"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
{
    name: "shell_job_list",
    title: "List background jobs",
    description: "List persistent background-job metadata and current running state.",
    inputSchema: { type: "object", additionalProperties: false },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
{
    name: "shell_job_kill",
    title: "Stop background job",
    description: "Send a signal to the background job's process group. Defaults to SIGTERM.",
    inputSchema: {
      type: "object",
      properties: {
        job_id: { type: "string" },
        signal: { type: "string", enum: ["SIGTERM", "SIGKILL", "SIGINT", "SIGHUP"], default: "SIGTERM" },
      },
      required: ["job_id"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, idempotentHint: false, openWorldHint: false },
  }
];

// Both foreground and background shell commands begin as durable, supervised jobs.
// No command is re-executed during promotion from exec to job.status.
async function createJob(context, options) {
  const { HOME, SHELL, JOB_DIR, resolvePath, validateWorkingDirectory, crypto, fs, fsp, path,
    spawn, mergedEnv, nowIso, writeJobMetadata, processRunning, killProcessGroup } = context;
  const { command } = options;
          const cwd = resolvePath(options.cwd ?? HOME);
          await validateWorkingDirectory(cwd);
          const env = options.env ?? {};
          const input = options.stdin;
          const label = (options.label ?? "background-job").replace(/[^A-Za-z0-9._-]+/g, "-").slice(0, 80) || "background-job";
          const id = `${Date.now()}-${crypto.randomBytes(5).toString("hex")}-${label}`;
          const stdoutPath = path.join(JOB_DIR, `${id}.stdout.log`);
          const stderrPath = path.join(JOB_DIR, `${id}.stderr.log`);
          let stdoutFd;
          let stderrFd;
          let child;
          let stdinPath;
          let stdinFd;
          try {
            stdoutFd = fs.openSync(stdoutPath, "a", 0o600);
            stderrFd = fs.openSync(stderrPath, "a", 0o600);
            if (input !== undefined) {
              stdinPath = path.join(JOB_DIR, `${id}.stdin`);
              await fsp.writeFile(stdinPath, input, { mode: 0o600 });
              stdinFd = fs.openSync(stdinPath, "r");
            }
            child = spawn(SHELL, ["-lc", command], {
              cwd,
              env: mergedEnv(env),
              detached: true,
              stdio: [stdinFd ?? "ignore", stdoutFd, stderrFd],
            });
            await new Promise((resolve, reject) => {
              child.once("spawn", resolve);
              child.once("error", reject);
            });
          } catch (error) {
            await Promise.allSettled([fsp.unlink(stdoutPath), fsp.unlink(stderrPath), ...(stdinPath ? [fsp.unlink(stdinPath)] : [])]);
            throw error;
          } finally {
            if (stdoutFd !== undefined) fs.closeSync(stdoutFd);
            if (stderrFd !== undefined) fs.closeSync(stderrFd);
            if (stdinFd !== undefined) fs.closeSync(stdinFd);
          }
          child.unref();
          let metadata = {
            id,
            label,
            pid: child.pid,
            processGroupId: child.pid,
            command,
            cwd,
            startedAt: nowIso(),
            stdoutPath,
            stderrPath,
            exitCode: null,
            signal: null,
            finishedAt: null,
          };
          let metadataWritten = false;
          let exitResult = null;
          let exitPersist = Promise.resolve();
          const persistExit = () => {
            if (!metadataWritten || !exitResult) return;
            metadata = { ...metadata, ...exitResult };
            exitPersist = exitPersist.then(() => writeJobMetadata(metadata)).catch(() => {});
          };
          child.once("close", (code, signal) => {
            if (stdinPath) fsp.unlink(stdinPath).catch(() => {});
            exitResult = { exitCode: code, signal, finishedAt: nowIso() };
            persistExit();
          });
          // Fail closed, as pty sessions and federated children already do. This job is
          // detached and unref'd, so if the metadata write fails (EACCES on JOB_DIR, ENOSPC)
          // nothing in $DATA_DIR/jobs names it and scripts/disable.sh can never find it — an
          // unrestricted job invisible to the kill switch. Kill it and report, rather than
          // leave it running unrecorded.
          try {
            await writeJobMetadata(metadata);
            metadataWritten = true;
            persistExit();
            await exitPersist;
          } catch (metadataError) {
            killProcessGroup(child.pid, "SIGKILL");
            await Promise.allSettled([
              fsp.unlink(stdoutPath),
              fsp.unlink(stderrPath),
              fsp.unlink(path.join(JOB_DIR, `${id}.json`)),
            ]);
            throw new Error(
              `Could not record job metadata, so the job was killed rather than left unreclaimable: ${metadataError?.message || metadataError}`,
            );
          }
  return { ...metadata, running: processRunning(child.pid) };
}

export async function handleShell(name, args, context) {
  const { HOME, SHELL, JOB_DIR, DEFAULT_OUTPUT_BYTES, MAX_OUTPUT_BYTES, SHELL_EXEC_DEFAULT_TIMEOUT_MS, GUI_FOCUS_POLICY, readOperatorSettings, guiFocusRisk, consumeForegroundGuiApproval, normalizeEnv, optionalString, optionalInteger, resolvePath, validateWorkingDirectory, crypto, fs, fsp, path, spawn, mergedEnv, nowIso, writeJobMetadata, readJobMetadata, processRunning, tailFile, killProcessGroup, audit, runCommand, requireString } = context;
  switch (name) {
        case "shell_exec": {
          const command = requireString(args, "command");
          const cwd = optionalString(args, "cwd", HOME);
          const focusRisk = guiFocusRisk(command);
          const operatorSettings = await readOperatorSettings();
          let foregroundGrant = null;
          if (focusRisk && operatorSettings.strictApprovals) {
            foregroundGrant = await consumeForegroundGuiApproval(focusRisk);
            if (!foregroundGrant) {
              const error = new Error(`Desktop GUI automation is blocked because Strict approvals is enabled (${focusRisk.reason}; targets: ${focusRisk.apps.join(", ")}). Use a background-capable API/connector/extension instead, or approve a one-time foreground action with scripts/approve-foreground-gui.sh.`);
              error.code = "GUI_FOCUS_BLOCKED";
              await audit(name, args, { guiFocusPolicy: GUI_FOCUS_POLICY, strictApprovals: true, blocked: true, focusRisk }, error);
              throw error;
            }
          }
          const env = normalizeEnv(args?.env);
          const stdin = optionalString(args, "stdin", undefined);
          const timeoutMs = optionalInteger(args, "timeout", SHELL_EXEC_DEFAULT_TIMEOUT_MS, 0, 1_800_000);
          const maxOutputBytes = optionalInteger(args, "max_output_bytes", SHELL_INLINE_BYTES, 0, MAX_OUTPUT_BYTES) || SHELL_INLINE_BYTES;
          const effectiveCwd = resolvePath(cwd);
          await validateWorkingDirectory(effectiveCwd);
          const startedAt = Date.now();
          // Register with the durable job supervisor before waiting. Promotion never
          // re-executes or re-parents the running process.
          const job = await createJob(context, { command, cwd: effectiveCwd, env, stdin, label: "exec" });
          await audit(name, args, { jobId: job.id, pid: job.pid, state: "started" });
          const diagnostic = async (file) => {
            const handle = await fsp.open(file, "r");
            try {
              const stat = await handle.stat();
              const size = Math.min(stat.size, 2048);
              const buffer = Buffer.alloc(size);
              await handle.read(buffer, 0, size, stat.size - size);
              return buffer.toString("utf8");
            } finally { await handle.close(); }
          };
          const readOutput = async (file, suffix) => {
            const stat = await fsp.stat(file);
            if (stat.size <= maxOutputBytes) return { text: await fsp.readFile(file, "utf8"), file: null, bytes: stat.size };
            const outputDirectory = await fsp.mkdtemp(path.join(os.tmpdir(), "neoy-outputs-"));
            await fsp.chmod(outputDirectory, 0o700);
            const destination = path.join(outputDirectory, suffix);
            await fsp.copyFile(file, destination);
            await fsp.chmod(destination, 0o600);
            const handle = await fsp.open(file, "r");
            let preview;
            try {
              const buffer = Buffer.alloc(maxOutputBytes);
              const { bytesRead } = await handle.read(buffer, 0, maxOutputBytes, 0);
              preview = buffer.subarray(0, bytesRead).toString("utf8");
            } finally { await handle.close(); }
            return { text: preview, file: destination, bytes: stat.size };
          };
          const promotionMs = context.SHELL_PROMOTION_MS ?? SHELL_PROMOTION_MS;
          while (true) {
            const metadata = await readJobMetadata(job.id);
            const elapsed = Date.now() - startedAt;
            if (metadata.finishedAt) {
              const [out, err] = await Promise.all([readOutput(job.stdoutPath, "stdout.log"), readOutput(job.stderrPath, "stderr.log")]);
              const result = {
                command, shell: SHELL, cwd: effectiveCwd, exitCode: metadata.exitCode,
                signal: metadata.signal, timedOut: false, durationMs: elapsed,
                stdout: out.text, stderr: err.text,
                stdoutFile: out.file, stderrFile: err.file,
                capturedStdoutBytes: out.bytes, capturedStderrBytes: err.bytes,
                stdoutTruncated: false, stderrTruncated: false,
              };
              await audit(name, args, {
                exitCode: result.exitCode, durationMs: elapsed, jobId: job.id,
                stdoutFile: out.file, stderrFile: err.file,
                ...(result.exitCode !== 0 ? { stderrPreview: await diagnostic(job.stderrPath) } : {}),
              });
              return result;
            }
            if (elapsed >= Math.min(timeoutMs, promotionMs)) {
              await audit(name, args, { jobId: job.id, running: true, durationMs: elapsed });
              return { status: "running", jobId: job.id, pid: job.pid,
                processGroupId: job.processGroupId, durationMs: elapsed,
                stdoutFile: job.stdoutPath, stderrFile: job.stderrPath };
            }
            await new Promise(resolve => setTimeout(resolve, 50));
          }
        }
    
        case "shell_start": {
          const command = requireString(args, "command");
          const operatorSettings = await readOperatorSettings();
          const focusRisk = guiFocusRisk(command);
          if (focusRisk && operatorSettings.strictApprovals) {
            const foregroundGrant = await consumeForegroundGuiApproval(focusRisk);
            if (!foregroundGrant) {
              const error = new Error(`Desktop GUI automation is blocked because Strict approvals is enabled (${focusRisk.reason}; targets: ${focusRisk.apps.join(", ")}). Approve a one-time foreground action with scripts/approve-foreground-gui.sh, or use a background-capable API/web path.`);
              error.code = "GUI_FOCUS_BLOCKED";
              await audit(name, args, { guiFocusPolicy: GUI_FOCUS_POLICY, strictApprovals: true, blocked: true, focusRisk }, error);
              throw error;
            }
          }
          const job = await createJob(context, {
            command, cwd: optionalString(args, "cwd", HOME), env: normalizeEnv(args?.env),
            label: optionalString(args, "label", "background-job"),
          });
          await audit(name, args, { jobId: job.id, pid: job.pid });
          return job;
        }

        case "shell_job_status": {
          const jobId = requireString(args, "job_id");
          const maxLogBytes = optionalInteger(args, "max_log_bytes", 100_000, 1_024, 8_000_000);
          const metadata = await readJobMetadata(jobId);
          const [stdout, stderrTail] = await Promise.all([
            tailFile(metadata.stdoutPath, maxLogBytes),
            tailFile(metadata.stderrPath, maxLogBytes),
          ]);
          const result = { ...metadata, running: processRunning(metadata.pid), stdout, stderr: stderrTail };
          await audit(name, args, { jobId, running: result.running });
          return result;
        }
    
        case "shell_job_list": {
          const files = (await fsp.readdir(JOB_DIR)).filter((entry) => entry.endsWith(".json")).sort().reverse();
          const jobs = [];
          for (const file of files.slice(0, 1000)) {
            try {
              const metadata = JSON.parse(await fsp.readFile(path.join(JOB_DIR, file), "utf8"));
              jobs.push({ ...metadata, running: processRunning(metadata.pid) });
            } catch (error) {
              jobs.push({ metadataFile: file, error: String(error?.message || error) });
            }
          }
          await audit(name, args, { count: jobs.length });
          return { jobs };
        }
    
        case "shell_job_kill": {
          const jobId = requireString(args, "job_id");
          const signal = optionalString(args, "signal", "SIGTERM");
          const metadata = await readJobMetadata(jobId);
          let killed = false;
          try {
            process.kill(-metadata.processGroupId, signal);
            killed = true;
          } catch (error) {
            if (error?.code !== "ESRCH") throw error;
          }
          const result = { jobId, pid: metadata.pid, signal, killed, running: processRunning(metadata.pid) };
          await audit(name, args, result);
          return result;
        }
    default: throw new Error("Unknown shell tool: " + name);
  }
}
