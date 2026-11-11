// Private Core housekeeping. No MCP surface and never signals a process.
// Keep this policy in parity with rust/src/jobs.rs (72h / 2000 / hourly).
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const JOB_GC_MAX_AGE_MS = 72 * 60 * 60 * 1000;
export const JOB_GC_MAX_COMPLETED = 2_000;
export const JOB_GC_MAX_SWEEP = 1_000;
export const JOB_GC_INTERVAL_MS = 60 * 60 * 1000;
const PTY_GC_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000;
const ID = /^[A-Za-z0-9._-]{1,128}$/;
const FILE = /^(?!pty_)([A-Za-z0-9._-]{1,128})\.json$/;
const PTY_FILE = /^pty_[A-Za-z0-9_-]{1,120}\.json$/;

function dateMs(iso) {
  const time = typeof iso === "string" ? Date.parse(iso) : NaN;
  return Number.isFinite(time) ? time : null;
}

// A PID alone is not an identity: macOS can recycle PIDs quickly. Compare the
// actual process creation time to the original job's startedAt (minute tolerance
// for older runtimes). If ps cannot be read, fail closed for unfinished jobs.
function snapshotProcesses() {
  let output;
  try {
    output = execFileSync("/bin/ps", ["-axo", "pid=,pgid=,lstart="], {
      encoding: "utf8", timeout: 10_000, maxBuffer: 8_000_000,
    });
  } catch { return null; }
  const processes = new Map();
  // null means descendants remain but the original group leader is gone.
  const groups = new Map();
  for (const line of output.split("\n")) {
    const match = line.trim().match(/^(\d+)\s+(\d+)\s+(.+)$/);
    if (!match) continue;
    const timestamp = Date.parse(match[3]);
    if (!Number.isFinite(timestamp)) continue;
    processes.set(Number(match[1]), timestamp);
    const pid = Number(match[1]), pgid = Number(match[2]);
    if (!groups.has(pgid)) groups.set(pgid, null);
    if (pid === pgid) groups.set(pgid, timestamp);
  }
  processes.groups = groups;
  return processes.has(process.pid) ? processes : null;
}

function originalProcessAlive(record, processStartTimes) {
  if (!processStartTimes) return true; // unknown means protected
  const pid = record.pid;
  const started = dateMs(record.startedAt);
  if (!Number.isSafeInteger(pid) || pid <= 1 || started === null) return true;
  // Protect orphaned descendants, but do not confuse a recycled PGID with
  // the original job. A *present* leader whose start time differs proves reuse.
  const pgid = record.processGroupId;
  if (Number.isSafeInteger(pgid) && pgid > 1 && processStartTimes.groups?.has(pgid)) {
    const leaderStart = processStartTimes.groups.get(pgid);
    if (leaderStart === null || Math.abs(leaderStart - started) < 120_000) return true;
  }
  const processStart = processStartTimes.get(pid);
  if (processStart === undefined) return false;
  return Math.abs(processStart - started) < 120_000;
}

function safeOwnedLog(jobDir, id, value, suffix) {
  if (!ID.test(id) || typeof value !== "string") return null;
  const expected = path.join(jobDir, `${id}.${suffix}`);
  return path.resolve(value) === expected ? expected : null;
}

async function removeCandidate(candidate, jobDir, now, processStartTimes, dryRun) {
  const { filename, id, pty } = candidate;
  const metadata = path.join(jobDir, filename);
  let st;
  try { st = await fsp.lstat(metadata); } catch { return false; }
  if (!st.isFile() || st.isSymbolicLink()) return false;
  let doc;
  try { doc = JSON.parse(await fsp.readFile(metadata, "utf8")); } catch { return false; }
  if (doc.id !== id || !ID.test(id)) return false;
  if (pty) {
    if (doc.kind !== "pty" || now - (dateMs(doc.startedAt) ?? now) < PTY_GC_MAX_AGE_MS) return false;
    if (originalProcessAlive(doc, processStartTimes)) return false;
    if (doc.helperPid && originalProcessAlive({pid: doc.helperPid, startedAt: doc.startedAt}, processStartTimes)) return false;
  } else {
    if (doc.finishedAt === null || doc.finishedAt === undefined) {
      if (originalProcessAlive(doc, processStartTimes)) return false;
      if (now - (dateMs(doc.startedAt) ?? now) < JOB_GC_MAX_AGE_MS) return false;
    } else if (originalProcessAlive(doc, processStartTimes)) {
      return false;
    }
  }
  if (dryRun) return true;
  // Move the validated metadata out of the public index first. Never follow a
  // symlink and never delete paths outside this exact Core-owned directory.
  const held = path.join(jobDir, `.gc-${id}-${process.pid}-${Math.random().toString(16).slice(2)}`);
  try { await fsp.rename(metadata, held); } catch { return false; }
  try {
    const check = await fsp.lstat(held);
    if (!check.isFile() || check.isSymbolicLink() || check.ino !== st.ino || check.dev !== st.dev) {
      await fsp.rename(held, metadata).catch(() => {});
      return false;
    }
    for (const [field, suffix] of [["stdoutPath", "stdout.log"], ["stderrPath", "stderr.log"]]) {
      const log = safeOwnedLog(jobDir, id, doc[field], suffix);
      if (log) {
        const stat = await fsp.lstat(log).catch(() => null);
        if (stat?.isFile() && !stat.isSymbolicLink()) await fsp.unlink(log).catch(() => {});
      }
    }
    // stdin is deleted on normal exit but may remain after a crash.
    const stdinPath = path.join(jobDir, `${id}.stdin`);
    const stdinStat = await fsp.lstat(stdinPath).catch(() => null);
    if (stdinStat?.isFile() && !stdinStat.isSymbolicLink()) await fsp.unlink(stdinPath).catch(() => {});
    await fsp.unlink(held);
    return true;
  } catch {
    await fsp.rename(held, metadata).catch(() => {});
    return false;
  }
}

export async function collectJobGarbage({ jobDir, dryRun = false, maxDeletes = JOB_GC_MAX_SWEEP,
  now = Date.now(), processStartTimes = snapshotProcesses() } = {}) {
  if (!path.isAbsolute(jobDir)) throw new Error("jobDir must be absolute");
  const root = path.resolve(jobDir);
  const names = await fsp.readdir(root);
  const completed = [], unfinished = [], ptys = [];
  let invalid = 0;
  for (const filename of names) {
    const regular = filename.match(FILE);
    const isPty = PTY_FILE.test(filename);
    if (!regular && !isPty) continue;
    const meta = path.join(root, filename);
    let stat;
    try { stat = await fsp.lstat(meta); } catch { continue; }
    if (!stat.isFile() || stat.isSymbolicLink()) { invalid++; continue; }
    let doc;
    try { doc = JSON.parse(await fsp.readFile(meta, "utf8")); } catch { invalid++; continue; }
    const id = regular ? regular[1] : filename.slice(0,-5);
    if (doc.id !== id || !Number.isSafeInteger(doc.pid) || !ID.test(id)) { invalid++; continue; }
    if (isPty) {
      if (doc.kind === "pty") ptys.push({filename,id,started:dateMs(doc.startedAt),pty:true});
      else invalid++;
    } else if (doc.finishedAt === null || doc.finishedAt === undefined) {
      unfinished.push({filename,id,started:dateMs(doc.startedAt),doc});
    } else {
      const finished = dateMs(doc.finishedAt);
      if (finished !== null) completed.push({filename,id,finished,doc});
      else invalid++;
    }
  }
  // Retain the most recent 2000 completed jobs and any further jobs younger
  // than 72 hours only until the max-count constraint requires their removal.
  completed.sort((a,b) => b.finished - a.finished || a.id.localeCompare(b.id));
  const toDelete = [];
  for (let index = 0; index < completed.length; index++) {
    const entry = completed[index];
    if (index >= JOB_GC_MAX_COMPLETED || now - entry.finished >= JOB_GC_MAX_AGE_MS) {
      toDelete.push({filename:entry.filename,id:entry.id,pty:false});
    }
  }
  for (const entry of unfinished) {
    if (entry.started !== null && now - entry.started >= JOB_GC_MAX_AGE_MS
        && !originalProcessAlive(entry.doc, processStartTimes)) {
      toDelete.push({filename:entry.filename,id:entry.id,pty:false});
    }
  }
  for (const entry of ptys) {
    if (entry.started !== null && now - entry.started >= PTY_GC_MAX_AGE_MS) {
      toDelete.push(entry);
    }
  }
  // Oldest first for prompt disk recovery; stop after a bounded amount of work.
  let deleted = 0;
  for (const candidate of toDelete.slice(0,Math.max(0,maxDeletes))) {
    if (await removeCandidate(candidate,root,now,processStartTimes,dryRun)) deleted++;
  }
  return {scanned: completed.length+unfinished.length+ptys.length, completed:completed.length,
    unfinished:unfinished.length, pty:ptys.length, invalid, eligible:toDelete.length,
    selected:Math.min(toDelete.length,Math.max(0,maxDeletes)), verified:deleted,
    dryRun, processSnapshotAvailable:processStartTimes !== null};
}

// The operator runs this explicitly for initial cleanup; the same function is
// used by the Node Core scheduler. No external service, privilege, or new MCP tool.
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const directoryIndex = args.indexOf("--job-dir");
  if (directoryIndex < 0 || !args[directoryIndex + 1]) {
    console.error("Usage: node job-gc.mjs --job-dir /absolute/path [--apply] [--max-deletes N]");
    process.exit(2);
  }
  const maxIndex = args.indexOf("--max-deletes");
  const maxDeletes = maxIndex >= 0 ? Number(args[maxIndex + 1]) : 100_000;
  if (!Number.isSafeInteger(maxDeletes) || maxDeletes < 0) throw Error("max-deletes must be a nonnegative integer");
  const result = await collectJobGarbage({ jobDir:args[directoryIndex + 1],
    dryRun:!args.includes("--apply"), maxDeletes });
  console.log(JSON.stringify(result));
}
