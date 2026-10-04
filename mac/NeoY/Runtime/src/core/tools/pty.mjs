#!/usr/bin/env node

import { execFileSync, spawn } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import fsp from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

function envValue(primary, legacy) {
  return process.env[primary] ?? process.env[legacy];
}

function clampInt(value, fallback, min, max) {
  const parsed = Number.parseInt(String(value ?? ""), 10);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(max, Math.max(min, parsed));
}

function nowIso() {
  return new Date().toISOString();
}

function stderr(message) {
  process.stderr.write(`[${nowIso()}] ${message}\n`);
}

const HOME = os.homedir();
const CORE_TOOLS_DIR = path.dirname(fileURLToPath(import.meta.url));
const PTY_HELPER_PERL = envValue("NEO_CORE_PTY_PERL", "MAC_DEV_BRIDGE_PTY_PERL") || "/usr/bin/perl";
const PTY_HELPER_PL = envValue("NEO_CORE_PTY_HELPER", "MAC_DEV_BRIDGE_PTY_HELPER") || path.join(CORE_TOOLS_DIR, "..", "lib", "ptyhelper.pl");
const PTY_MAX_SESSIONS = clampInt(envValue("NEO_CORE_PTY_MAX_SESSIONS", "MAC_DEV_BRIDGE_PTY_MAX_SESSIONS"), 8, 1, 64);
const PTY_RING_BYTES = clampInt(envValue("NEO_CORE_PTY_RING_BYTES", "MAC_DEV_BRIDGE_PTY_RING_BYTES"), 262_144, 4_096, 4_000_000);
const PTY_RING_GLOBAL_BYTES = PTY_MAX_SESSIONS * PTY_RING_BYTES;
const PTY_IDLE_TIMEOUT_MS = clampInt(envValue("NEO_CORE_PTY_IDLE_TIMEOUT_MS", "MAC_DEV_BRIDGE_PTY_IDLE_TIMEOUT_MS"), 900_000, 1_000, 3_600_000);
const PTY_MAX_LIFETIME_MS = clampInt(envValue("NEO_CORE_PTY_MAX_LIFETIME_MS", "MAC_DEV_BRIDGE_PTY_MAX_LIFETIME_MS"), 28_800_000, 5_000, 86_400_000);
const PTY_WRITE_MAX = 65_536;
const PTY_START_TIMEOUT_MS = clampInt(envValue("NEO_CORE_PTY_START_TIMEOUT_MS", "MAC_DEV_BRIDGE_PTY_START_TIMEOUT_MS"), 5_000, 500, 60_000);
const PTY_ACK_TIMEOUT_MS = 2_000;
const PTY_CLOSE_GRACE_MS = 2_000;
const PTY_HELPER_CLOSE_GRACE_MS = 250;
const PTY_MAX_CANON = 1024;
const PTY_SWEEP_MS = 5_000;
const PTY_TERMS = ["xterm-256color", "xterm", "vt100", "dumb"];
const PTY_SIGNALS = ["INT", "TERM", "KILL", "HUP", "QUIT", "USR1", "USR2", "WINCH", "TSTP", "CONT"];
const PTS_PATTERN = /^\/dev\/tty[a-z0-9]{1,12}$/;
const PTY_TTY_SCAN_MAX = 64;
const PTY_TTY_SCAN_TIMEOUT_MS = 1_000;
const PTY_TTY_SCAN_BUDGET_MS = 1_000;
const PTY_TTY_REFRESH_MS = 150;

// Interactive pty sessions
// ---------------------------------------------------------------------------

// leaderPid is stored separately from the child handle on purpose: the handle can
// be gone (helper exited) while the process group it started is very much not.
const ptySessions = new Map();
let ptyAvailable = false;
let ptySweeper = null;
let ptyRuntime = null;

export function configurePty(context) {
  ptyRuntime = context;
}

export function ptyStatus() {
  return {
    available: ptyAvailable,
    helper: ptyAvailable ? { interpreter: PTY_HELPER_PERL, script: PTY_HELPER_PL } : null,
    limits: {
      maxSessions: PTY_MAX_SESSIONS,
      ringBytesPerSession: PTY_RING_BYTES,
      ringBytesGlobal: PTY_RING_GLOBAL_BYTES,
      idleTimeoutMs: PTY_IDLE_TIMEOUT_MS,
      maxLifetimeMs: PTY_MAX_LIFETIME_MS,
      writeMaxBytes: PTY_WRITE_MAX,
    },
    sessions: [...ptySessions.values()].map(ptySessionSummary),
  };
}

export function teardownPty(reason = "revoked") {
  return killPtySessions(reason);
}

function killProcessGroup(pgid, signal) {
  if (!Number.isInteger(pgid) || pgid <= 1) return "INVALID_TARGET";
  try {
    process.kill(-pgid, signal);
    return null;
  } catch (error) {
    return error?.code || String(error?.message || error);
  }
}

// UTF-8 continuation bytes are 10xxxxxx. Reads are byte-ranged, so without these
// two the boundary between consecutive reads manufactures U+FFFD: measured, 48 of
// 54 arbitrary slices of mixed-width text were corrupted.
function alignUtf8Start(buf, index) {
  let i = index;
  let skipped = 0;
  while (i < buf.length && (buf[i] & 0xc0) === 0x80 && skipped < 4) {
    i += 1;
    skipped += 1;
  }
  return i;
}

// Trims an incomplete trailing sequence from an exclusive end index, so a
// codepoint split across two reads is emitted whole by the second one.
function alignUtf8End(buf, end) {
  let j = end - 1;
  let continuations = 0;
  while (j >= 0 && (buf[j] & 0xc0) === 0x80 && continuations < 3) {
    j -= 1;
    continuations += 1;
  }
  if (j < 0) return end;
  const lead = buf[j];
  const need = lead >= 0xf0 ? 4 : lead >= 0xe0 ? 3 : lead >= 0xc0 ? 2 : 1;
  if (need === 1) return end;
  return continuations + 1 >= need ? end : j;
}

// OSC (terminated by BEL or ST), two-character escapes, then CSI. A realistic
// coloured build was 47.7% escape bytes, so a model reading raw output spends
// half its context on colour codes.
const ANSI_ESCAPES = /\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-Z\\-_]|\x1b\[[0-9;?]*[ -\/]*[@-~]/g;

// ANSI_ESCAPES only matches a WHOLE sequence. A read boundary that falls inside
// one therefore defeats stripping in both directions: the first slice ends with a
// bare ESC (no following byte to match) and the second begins with "[0m" (no ESC),
// so both halves survive and reappear when the client concatenates. Measured: 300
// coloured lines read whole contained no ESC; the same transcript paged at 1024
// bytes did. An unterminated escape gets the same holdback a partial codepoint
// already gets.
//
// Bounded scan-back so a program emitting an endless CSI parameter run cannot make
// every read shrink to nothing; past the bound the slice is emitted as-is and the
// progress guarantee in ptySliceForCursor still applies.
const ANSI_MAX_HOLDBACK = 4096;

// True when a complete escape sequence starting at `k` ends before `end`.
function ansiSequenceComplete(buf, k, end) {
  if (k + 1 >= end) return false;
  const introducer = buf[k + 1];
  if (introducer === 0x5d) {
    // OSC: ESC ] ... terminated by BEL or ST (ESC \).
    for (let i = k + 2; i < end; i += 1) {
      if (buf[i] === 0x07) return true;
      if (buf[i] === 0x1b) return i + 1 < end && buf[i + 1] === 0x5c;
    }
    return false;
  }
  if (introducer === 0x5b) {
    // CSI: ESC [ parameters intermediates final.
    let i = k + 2;
    while (i < end && ((buf[i] >= 0x30 && buf[i] <= 0x39) || buf[i] === 0x3b || buf[i] === 0x3f)) i += 1;
    while (i < end && buf[i] >= 0x20 && buf[i] <= 0x2f) i += 1;
    return i < end && buf[i] >= 0x40 && buf[i] <= 0x7e;
  }
  // Either a complete two-character escape or not an escape at all. Neither can be
  // completed by the next read, so holding it back would stall rather than help.
  return true;
}

function trimPartialAnsi(buf, start, end) {
  const floor = Math.max(start, end - ANSI_MAX_HOLDBACK);
  for (let k = end - 1; k >= floor; k -= 1) {
    if (buf[k] !== 0x1b) continue;
    return ansiSequenceComplete(buf, k, end) ? end : k;
  }
  return end;
}

// Splits a payload the way the canonical line discipline sees it: runs of bytes
// between \r or \n. `first` is the run that continues whatever line is already in
// the discipline's buffer, `trailing` is what is left unterminated for the next
// write to continue.
function canonicalRuns(payload) {
  let first = -1;
  let longest = 0;
  let current = 0;
  let hasTerminator = false;
  for (let i = 0; i < payload.length; i += 1) {
    const byte = payload[i];
    if (byte === 0x0a || byte === 0x0d) {
      if (first < 0) first = current;
      hasTerminator = true;
      if (current > longest) longest = current;
      current = 0;
    } else {
      current += 1;
    }
  }
  if (current > longest) longest = current;
  if (first < 0) first = current;
  return { first, longest, trailing: current, hasTerminator };
}

function renderPtyText(bytes, { stripAnsi, collapseCarriageReturns }) {
  let text = bytes.toString("utf8");
  if (stripAnsi) text = text.replace(ANSI_ESCAPES, "");
  if (collapseCarriageReturns) {
    // CRLF folding belongs to this flag, not above it. A tty in ONLCR turns every
    // \n into \r\n, so folding unconditionally would mean collapse_carriage_returns
    // false is not actually raw — and the difference between a real pty and a pipe
    // would be unobservable through this tool.
    //
    // \r+ and not \r: a program that already emits CRLF arrives at the master as
    // \r\r\n, because ONLCR expands the \n it wrote. Folding exactly one CR left a
    // trailing CR on the line, and the redraw collapse below then kept only what
    // followed the last CR — which was nothing. Measured: printf 'alpha\r\nbeta\r\n'
    // rendered as two empty lines. Everything that prints CRLF on a terminal (ssh,
    // git, node's readline, every TUI) hit this.
    text = text.replace(/\r+\n/g, "\n");
    // A CR-redrawn progress line is ~30 overlapping copies of itself otherwise.
    text = text
      .split("\n")
      .map((line) => {
        const last = line.lastIndexOf("\r");
        return last === -1 ? line : line.slice(last + 1);
      })
      .join("\n");
  }
  return text;
}

// Fixed-capacity ring addressed by an ABSOLUTE byte offset.
//
// Two properties matter more than they look. It is allocated once at capacity,
// because appending to a chunk list from a pty is a remote-driven memory leak
// (`yes` in a session out-produces any reader) — the same class already fixed for
// HTTP request bodies. And reads are pure functions of an offset rather than a
// drain: this endpoint is public and retried, and a drain-on-read buffer destroys
// output on the first duplicated poll.
function createPtyRing(capacity) {
  const buf = Buffer.allocUnsafe(capacity);
  let writePos = 0;
  let total = 0;
  return {
    append(chunk) {
      total += chunk.length;
      // A single chunk larger than the ring keeps its NEWEST bytes. boundedCollector
      // drops the newest instead, which is right for one-shot capture and wrong for
      // a terminal, where the last screen is the one being looked at.
      const data = chunk.length > capacity ? chunk.subarray(chunk.length - capacity) : chunk;
      const firstLen = Math.min(data.length, capacity - writePos);
      data.copy(buf, writePos, 0, firstLen);
      if (firstLen < data.length) data.copy(buf, 0, firstLen);
      writePos = (writePos + data.length) % capacity;
    },
    get total() {
      return total;
    },
    get retained() {
      return Math.min(total, capacity);
    },
    get base() {
      return total - Math.min(total, capacity);
    },
    copy(fromAbsolute, length) {
      const out = Buffer.allocUnsafe(length);
      if (length === 0) return out;
      const retained = Math.min(total, capacity);
      const rel = fromAbsolute - (total - retained);
      const start = (writePos - retained + rel + capacity * 2) % capacity;
      const firstLen = Math.min(length, capacity - start);
      buf.copy(out, 0, start, start + firstLen);
      if (firstLen < length) buf.copy(out, firstLen, 0, length - firstLen);
      return out;
    },
  };
}

function ptySliceForCursor(session, cursor, maxBytes) {
  const ring = session.ring;
  const total = ring.total;
  const base = ring.base;
  const startAbsolute = Math.min(Math.max(cursor, base), total);
  const lostBytes = Math.max(0, base - cursor);
  const want = Math.min(maxBytes, total - startAbsolute);
  const raw = ring.copy(startAbsolute, want);
  // A cursor that fell behind the ring lands at an arbitrary byte, which is the
  // one case where the START of a slice can be mid-codepoint.
  let start = lostBytes > 0 ? alignUtf8Start(raw, 0) : 0;
  let end = raw.length;
  const moreFollows = startAbsolute + want < total;
  if (moreFollows || !session.exited) {
    end = alignUtf8End(raw, end);
    // An escape sequence split by the boundary is held back whole, for the same
    // reason and by the same rule as a partial codepoint.
    end = trimPartialAnsi(raw, start, end);
    // A lone trailing CR is held back for the same reason as a partial codepoint:
    // a read boundary between CR and LF otherwise emits a bare CR that no longer
    // collapses against its line.
    if (end > start && raw[end - 1] === 0x0d) end -= 1;
  }
  // Progress guarantee. Reachable only if max_bytes were smaller than one
  // codepoint, which the schema's 1024 minimum forbids; a silent stall would be
  // indistinguishable from a hung program, so refuse to create one.
  if (end <= start && want > 0 && moreFollows) end = raw.length;
  if (end < start) end = start;
  return {
    bytes: raw.subarray(start, end),
    nextCursor: startAbsolute + end,
    lostBytes,
    truncated: startAbsolute + end < total,
    totalBytes: total,
    retainedBytes: ring.retained,
  };
}

// fd 2 carries one JSON status line per event. Bounded, because an unterminated
// line from a helper must not grow this process without limit.
function attachHelperEvents(child, onEvent) {
  let pending = "";
  child.stderr.on("data", (chunk) => {
    pending += chunk.toString("utf8");
    if (pending.length > 65_536) {
      stderr("pty helper status line exceeded 64 KiB; discarding it.");
      pending = "";
      return;
    }
    let newline;
    while ((newline = pending.indexOf("\n")) >= 0) {
      const line = pending.slice(0, newline);
      pending = pending.slice(newline + 1);
      if (!line.trim()) continue;
      let event;
      try {
        event = JSON.parse(line);
      } catch {
        stderr(`pty helper emitted a non-JSON status line: ${line.slice(0, 200)}`);
        continue;
      }
      onEvent(event);
    }
  });
}

function spawnPtyHelper({ command, args, cwd, env, cols, rows }) {
  // detached: false is deliberate, and the opposite of shell_start. Reproducing
  // shell_start's detached + unref'd pattern left the helper reparented to PID 1,
  // still executing, with its pipes broken and no way for the bridge to reach it:
  // an orphaned unrestricted shell outliving revocation. Staying attached is also
  // what makes stdin EOF a reliable "my bridge is gone" signal for the helper.
  return spawn(PTY_HELPER_PERL, [PTY_HELPER_PL, String(cols), String(rows), "--", command, ...args], {
    cwd,
    env,
    detached: false,
    stdio: ["pipe", "pipe", "pipe", "pipe"],
  });
}

// The pty_* tools are advertised only if a real pty can be allocated, resized, and
// read back on this machine. The ioctl request numbers in ptyhelper.pl are
// hardcoded Darwin constants and /usr/bin/perl could be removed by a future macOS,
// so the failure mode has to be a loud absence rather than six tools that fail at
// call time — or worse, a pty_resize that returns the numbers it was handed.
async function probePtySupport() {
  try {
    await fsp.access(PTY_HELPER_PERL, fs.constants.X_OK);
    await fsp.access(PTY_HELPER_PL, fs.constants.R_OK);
  } catch (error) {
    stderr(`pty helper unavailable (${error?.code || error}); pty_* tools will not be advertised.`);
    return false;
  }
  return await new Promise((resolve) => {
    let settled = false;
    let leaderPid = null;
    let child;
    let timer = null;
    const finish = (ok, why) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      killProcessGroup(leaderPid, "SIGKILL");
      try {
        child.kill("SIGKILL");
      } catch {}
      if (!ok) stderr(`pty support self-test failed (${why}); pty_* tools will not be advertised.`);
      resolve(ok);
    };
    try {
      child = spawnPtyHelper({
        command: "/bin/cat",
        args: [],
        cwd: HOME,
        env: { PATH: process.env.PATH || "/usr/bin:/bin", HOME, TERM: "dumb" },
        cols: 120,
        rows: 40,
      });
    } catch (error) {
      stderr(`pty support self-test could not spawn the helper (${error?.message || error}).`);
      resolve(false);
      return;
    }
    child.once("error", (error) => finish(false, error?.message || error));
    child.stdin.on("error", () => {});
    child.stdio[3].on("error", () => {});
    // Drained and discarded: an unread stdout pipe fills, which would block the
    // helper in syswrite and make the self-test time out for the wrong reason.
    child.stdout.resume();
    attachHelperEvents(child, (event) => {
      if (event.event === "started") {
        leaderPid = event.pid;
        // Deliberately a different geometry from the one it started with: if
        // TIOCSWINSZ were a no-op, the read-back would still report 120x40.
        child.stdio[3].write(`${JSON.stringify({ op: "resize", cols: 133, rows: 41 })}\n`);
      } else if (event.event === "fatal") {
        finish(false, event.error);
      } else if (event.event === "resize") {
        const ok = (event.ok === 1 || event.ok === true) && event.cols === 133 && event.rows === 41;
        finish(ok, `winsize read-back was ${event.cols}x${event.rows}`);
      } else if (event.event === "exited") {
        finish(false, "self-test child exited before the resize was confirmed");
      }
    });
    child.once("close", () => finish(false, "helper exited before confirming a resize"));
    timer = setTimeout(() => finish(false, `no confirmation within ${PTY_START_TIMEOUT_MS}ms`), PTY_START_TIMEOUT_MS);
    timer.unref();
  });
}

export const ptyReady = probePtySupport().then((ok) => {
  ptyAvailable = ok;
  return ok;
});

// Started eagerly, here, rather than on first use. tools/list is answered with
// ttlMs 300_000 and capabilities.tools.listChanged is false, and mcp-http.mjs
// drops id-less messages so notifications/tools/list_changed never reaches the
// client — a provider that finishes starting after the first tools/list would be
// invisible for five minutes with no way to correct it.
// Tools are filtered rather than removed from the static array so tools/list and
// the tools/call membership gate cannot disagree. The gate rejects anything absent
// from the advertised set with -32601, so a dispatchTool case reached through only
// one of the two would be unreachable in one direction and unguarded in the other.
function livePtySessions() {
  return [...ptySessions.values()].filter((session) => !session.exited);
}

function ptyError(code, message) {
  const error = new Error(message);
  error.code = code;
  return error;
}

function getPtySession(sessionId) {
  const session = ptySessions.get(sessionId);
  if (!session) {
    // The hint matters: without it a model whose session id is stale polls a dead
    // id forever instead of starting a new session.
    throw ptyError("PTY_NO_SESSION", `Unknown pty session '${sessionId}' (bridge restarted; pty sessions do not persist, and closed sessions are eventually evicted). Start a new one with pty_start.`);
  }
  return session;
}

// Same character class readJobMetadata enforces, because the id becomes a filename
// in the jobs directory.
function requirePtySessionId(args) {
  const sessionId = requireString(args, "session_id");
  if (!/^[A-Za-z0-9._-]{1,128}$/.test(sessionId)) throw new Error("Invalid session_id");
  return sessionId;
}

// Long-poll for new output. Opt-in (wait_ms defaults to 0) and always resolved by
// a timer as well as by data, so a session that never speaks again cannot hold a
// request open.
function waitForPtyOutput(session, waitMs) {
  return new Promise((resolve) => {
    let settled = false;
    const done = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      const index = session.outputWaiters.indexOf(done);
      if (index >= 0) session.outputWaiters.splice(index, 1);
      resolve();
    };
    const timer = setTimeout(done, waitMs);
    timer.unref();
    session.outputWaiters.push(done);
  });
}

// A SIGKILLed session leader stays visible to kill(2) as a zombie until whoever
// inherits it reaps it, so a single immediate check reports "not contained" for a
// group that is already dead. Bounded retry, and an honest false if it never goes.
// It also covers the processes that were sharing the session's controlling
// terminal. `leaderGroupGone` alone is what previously reported
// containmentVerified:true over a still-running background job.
async function verifyPtyContainment(session, timeoutMs) {
  const leaderPid = session.leaderPid;
  const recycled = session.ttyRecycled || new Set();
  const targets = session.ttyTargets ? [...session.ttyTargets.keys()].filter((pid) => !recycled.has(pid)) : [];
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const leaderGroupGone = processGroupGone(leaderPid);
    const survivors = targets.filter((pid) => !processGone(pid));
    if (leaderGroupGone && survivors.length === 0) {
      return { contained: true, leaderGroupGone, survivors: [] };
    }
    if (Date.now() >= deadline) return { contained: false, leaderGroupGone, survivors };
    await new Promise((r) => setTimeout(r, 25));
  }
}

function ptySessionSummary(session) {
  return {
    id: session.id,
    command: session.command,
    args: session.args,
    leaderPid: session.leaderPid,
    pts: session.pts,
    cols: session.cols,
    rows: session.rows,
    totalBytes: session.ring.total,
    idleTimeoutMs: session.idleTimeoutMs,
    idleMs: Date.now() - session.lastActivityAt,
    exited: session.exited,
    exitCode: session.exitCode,
    exitSignal: session.exitSignal,
    closeReason: session.closeReason,
  };
}

function writePtyControl(session, op) {
  const control = session.child.stdio[3];
  if (!control || control.destroyed) throw ptyError("PTY_EXITED", `pty session '${session.id}' is no longer accepting control operations`);
  control.write(`${JSON.stringify(op)}\n`);
}

// Waits for one helper acknowledgement. Every timer here is per-call, cleared on
// settle, and unref'd, so a pending resize can never keep the process alive after
// its transport closed.
//
// `id` is the correlation. Matching on kind alone meant four concurrent
// pty_resize calls each resolved on whichever ack arrived first, so all four
// reported their own geometry as confirmed while the kernel held only one of
// them; the same FIFO-by-kind matching let a concurrent pty_signal and the TERM
// inside pty_close consume each other's answer.
function awaitPtyAck(session, kind, timeoutMs, id = null) {
  return new Promise((resolve, reject) => {
    const waiter = { kind, id, resolve: null, reject: null, timer: null };
    waiter.resolve = (event) => {
      clearTimeout(waiter.timer);
      remove();
      resolve(event);
    };
    waiter.reject = (error) => {
      clearTimeout(waiter.timer);
      remove();
      reject(error);
    };
    const remove = () => {
      const index = session.ackWaiters.indexOf(waiter);
      if (index >= 0) session.ackWaiters.splice(index, 1);
    };
    waiter.timer = setTimeout(() => {
      waiter.reject(ptyError(
        kind === "resize" ? "PTY_RESIZE_UNCONFIRMED" : "PTY_SIGNAL_UNCONFIRMED",
        `pty helper did not acknowledge the ${kind} within ${timeoutMs}ms`,
      ));
    }, timeoutMs);
    waiter.timer.unref();
    session.ackWaiters.push(waiter);
  });
}

function settlePtyAck(session, kind, event) {
  const eventId = Number.isInteger(event?.id) && event.id > 0 ? event.id : null;
  // Exact match first. The FIFO fallback covers only an ack that carries no id at
  // all, which a helper predating the correlation would produce; a request that
  // HAS an id is never settled by someone else's answer.
  let index = eventId === null
    ? -1
    : session.ackWaiters.findIndex((waiter) => waiter.kind === kind && waiter.id === eventId);
  if (index < 0 && eventId === null) {
    index = session.ackWaiters.findIndex((waiter) => waiter.kind === kind && waiter.id === null);
  }
  if (index < 0) return;
  session.ackWaiters[index].resolve(event);
}

// Allocates the correlation id, arms the waiter, then writes — in that order, so
// an ack cannot arrive before anyone is listening for it.
function sendPtyControl(session, kind, op, timeoutMs) {
  session.nextControlId += 1;
  const id = session.nextControlId;
  const pending = awaitPtyAck(session, kind, timeoutMs, id);
  try {
    writePtyControl(session, { ...op, id });
  } catch (error) {
    // The waiter must never be left armed: its timer would reject a promise
    // nobody is awaiting, which surfaces as an unhandled rejection.
    pending.catch(() => {});
    const waiter = session.ackWaiters.find((entry) => entry.id === id);
    if (waiter) waiter.reject(error);
    throw error;
  }
  return pending;
}

function failPtyAcks(session, error) {
  for (const waiter of [...session.ackWaiters]) waiter.reject(error);
}

function markPtyExited(session, { code = null, signal = null } = {}) {
  if (!session.exited) {
    session.exited = true;
    session.exitedAt = Date.now();
  }
  if (session.exitCode === null && code !== null) session.exitCode = code;
  if (session.exitSignal === null && signal) session.exitSignal = signal;
  failPtyAcks(session, ptyError("PTY_EXITED", `pty session '${session.id}' ended before the operation was acknowledged`));
  syncPtyTimers();
}

// Resolve the executable ourselves so a typo fails as pty_start's ENOENT. Left to
// exec(2) inside the helper it would instead be a session that starts "successfully"
// and is immediately dead with status 127 and one line of output.
function resolveExecutable(command, env) {
  if (command.includes("/")) {
    const resolved = ptyRuntime.resolvePath(command);
    try {
      fs.accessSync(resolved, fs.constants.X_OK);
    } catch (error) {
      throw ptyError("ENOENT", `Cannot execute '${resolved}': ${error?.code === "ENOENT" ? "no such file" : error?.code === "EACCES" ? "not executable" : error?.code || error}`);
    }
    return resolved;
  }
  const searchPath = (env.PATH || process.env.PATH || "/usr/bin:/bin:/usr/sbin:/sbin").split(":");
  for (const directory of searchPath) {
    if (!directory) continue;
    const candidate = path.join(directory, command);
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      return candidate;
    } catch {}
  }
  throw ptyError("ENOENT", `Cannot execute '${command}': not found on PATH`);
}

// The session table is capped including exited sessions, so the global retention
// bound really is PTY_MAX_SESSIONS x PTY_RING_BYTES. Keeping exited sessions
// forever so their final output stays readable is the same unbounded growth in a
// nicer costume.
function evictClosedPtySessions(pending = 0) {
  while (ptySessions.size + pending >= PTY_MAX_SESSIONS) {
    const oldest = [...ptySessions.values()]
      .filter((session) => session.exited)
      .sort((a, b) => (a.exitedAt || 0) - (b.exitedAt || 0))[0];
    if (!oldest) return false;
    ptySessions.delete(oldest.id);
  }
  return true;
}

// The cap has to be TAKEN, not merely checked.
//
// startPtySession used to test the cap and then await fsp.stat(cwd) before
// registering anything, so N concurrent pty_start calls all passed a check that
// none of them had yet invalidated. Measured against the shipped code: 60
// concurrent starts produced 58 live ptys against a cap of 8, 58 helper processes
// and 58 rings (15 MB where PTY_RING_GLOBAL_BYTES claims 2 MB). That matters
// beyond this process: kern.tty.ptmx_max is 511 SYSTEM-WIDE, so a large enough
// batch takes Terminal.app, iTerm and ssh away from the operator — the very path
// to scripts/disable.sh — and mcp-http.mjs deliberately caps neither connections
// nor concurrent requests.
//
// This counter bounds exactly one thing: how many pty_start calls may be between
// the cap check and their entry in ptySessions. A reserved slot is released on
// every exit from startPtySession, success or failure, so it cannot leak. It only
// ever makes the cap stricter (an in-flight start is counted while its session is
// also in the map, for the few ms between the two), never looser, and sequential
// use — one pty_start at a time — never sees a reservation at all.
let ptyStartsInFlight = 0;

function reservePtySlot() {
  if (livePtySessions().length + ptyStartsInFlight >= PTY_MAX_SESSIONS || !evictClosedPtySessions(ptyStartsInFlight)) {
    throw ptyError("PTY_SESSION_LIMIT", `pty session limit reached (${PTY_MAX_SESSIONS} live); close one with pty_close first.`);
  }
  ptyStartsInFlight += 1;
}

function releasePtySlot() {
  if (ptyStartsInFlight > 0) ptyStartsInFlight -= 1;
}

async function startPtySession(options) {
  if (!ptyAvailable) {
    throw ptyError("PTY_HELPER_UNAVAILABLE", `pty support is unavailable on this host (${PTY_HELPER_PERL} ${PTY_HELPER_PL}); the pty tools are not advertised.`);
  }
  // Everything above this line is synchronous, so the slot is taken before the
  // first suspension point and no concurrent caller can pass a check this one has
  // already consumed.
  reservePtySlot();
  try {
    return await startPtySessionInSlot(options);
  } finally {
    releasePtySlot();
  }
}

async function startPtySessionInSlot({ command, args, cwd, env, cols, rows, term, idleTimeoutMs, label }) {
  let cwdStat;
  try {
    cwdStat = await fsp.stat(cwd);
  } catch (error) {
    throw ptyError("PTY_BAD_CWD", `Working directory '${cwd}' is unusable: ${error?.code || error}`);
  }
  if (!cwdStat.isDirectory()) throw ptyError("PTY_BAD_CWD", `Working directory '${cwd}' is not a directory`);

  // TERM before the caller's overrides so an explicit env wins. Without TERM at
  // all, tput fails with "No value for $TERM"; with it, tput cols/lines matched
  // the real winsize.
  const childEnv = ptyRuntime.mergedEnv({ TERM: term, ...env });
  const resolved = resolveExecutable(command, childEnv);
  const id = `pty_${crypto.randomBytes(4).toString("hex")}`;
  const child = spawnPtyHelper({ command: resolved, args, cwd, env: childEnv, cols, rows });

  const session = {
    id,
    kind: "pty",
    label,
    command: resolved,
    args,
    cwd,
    term,
    cols,
    rows,
    child,
    helperPid: child.pid,
    leaderPid: null,
    pts: null,
    ring: createPtyRing(PTY_RING_BYTES),
    ackWaiters: [],
    nextControlId: 0,
    canonPendingBytes: 0,
    outputWaiters: [],
    idleTimeoutMs,
    createdAt: Date.now(),
    lastActivityAt: Date.now(),
    lastReadAt: null,
    exited: false,
    exitedAt: null,
    exitCode: null,
    exitSignal: null,
    closed: false,
    closeReason: null,
    startError: null,
    metadataPath: path.join(JOB_DIR, `${id}.json`),
  };
  ptySessions.set(id, session);
  syncPtyTimers();

  // Eagerly drained. A poll-driven read would leave the pipe full, which blocks
  // the helper in syswrite, which fills the pty, which blocks the CHILD — a
  // session that silently stalls its own build while the client thinks it is slow.
  child.stdout.on("data", (chunk) => {
    session.ring.append(chunk);
    const waiters = session.outputWaiters.splice(0, session.outputWaiters.length);
    for (const waiter of waiters) waiter();
  });
  // Mandatory on both writable ends: a stdin error after an accepted write emits
  // no 'exit', so without a handler it surfaces as a stray stream error while the
  // session keeps being reported as alive.
  child.stdin.on("error", (error) => {
    session.startError = session.startError || `stdin: ${error?.code || error?.message || error}`;
    markPtyExited(session);
  });
  child.stdio[3].on("error", () => {});
  child.once("error", (error) => {
    session.startError = String(error?.message || error);
    markPtyExited(session);
  });
  // Master-close raises SIGHUP, which usually suffices — but measured against
  // `trap '' HUP TERM INT` both the shell and its grandchild survived it. So the
  // group is reclaimed here explicitly instead of assuming the hangup worked.
  //
  // Bound to BOTH 'exit' and 'close'. 'close' waits for every stdio stream to end,
  // which a descriptor leaked into the session program can defer indefinitely;
  // 'exit' fires on the helper's death regardless. ptyhelper.pl now closes those
  // descriptors, so 'close' is no longer deferrable that way — but a reclaim path
  // that depends on the child cooperating is the kind of "containment" this
  // project has already shipped and had to retract, so it does not depend on it.
  const reclaimLeaderGroup = () => {
    if (!session.closed && session.leaderPid) killProcessGroup(session.leaderPid, "SIGKILL");
  };
  let helperCloseFallback = null;
  child.once("exit", () => {
    reclaimLeaderGroup();
    // Not markPtyExited() here: 'close' normally arrives within a tick and the
    // last of the transcript arrives with it, so marking the session finished on
    // 'exit' would cut off the final drain. The timer only exists for the case
    // where 'close' does not arrive at all.
    if (helperCloseFallback || session.exited) return;
    helperCloseFallback = setTimeout(() => {
      helperCloseFallback = null;
      stderr(`pty session ${session.id} helper exited without closing its pipes; marking the session ended.`);
      // Same reason as in the 'close' handler: this is the other way a session
      // can end without anyone calling killPtySession.
      sweepPtyTtyOnClose(session);
      markPtyExited(session);
    }, PTY_HELPER_CLOSE_GRACE_MS);
    helperCloseFallback.unref();
  });
  child.once("close", () => {
    if (helperCloseFallback) {
      clearTimeout(helperCloseFallback);
      helperCloseFallback = null;
    }
    reclaimLeaderGroup();
    // The group kill above cannot reach a background job: job control gave it its
    // own pgid. This is the only place a naturally-ended session gets swept.
    sweepPtyTtyOnClose(session);
    markPtyExited(session);
  });

  attachHelperEvents(child, (event) => {
    switch (event.event) {
      case "started":
        session.leaderPid = event.pid;
        session.pts = event.pts;
        session.cols = event.cols;
        session.rows = event.rows;
        break;
      case "resize":
        if (event.ok === 1 || event.ok === true) {
          session.cols = event.cols;
          session.rows = event.rows;
        }
        settlePtyAck(session, "resize", event);
        break;
      case "signal":
        settlePtyAck(session, "signal", event);
        break;
      case "termios":
        settlePtyAck(session, "termios", event);
        break;
      case "exited":
        markPtyExited(session, { code: event.code, signal: event.signal ? signalName(event.signal) : null });
        break;
      case "fatal":
        session.startError = event.error;
        markPtyExited(session);
        break;
      default:
        break;
    }
  });

  // Block until the helper reports readiness, so pty_start never returns an
  // optimistic success for a pty that was never allocated.
  await new Promise((resolve, reject) => {
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      reject(ptyError("PTY_START_TIMEOUT", `pty helper did not report readiness within ${PTY_START_TIMEOUT_MS}ms`));
    }, PTY_START_TIMEOUT_MS);
    timer.unref();
    const poll = setInterval(() => {
      if (settled) return;
      if (session.leaderPid) {
        settled = true;
        clearTimeout(timer);
        clearInterval(poll);
        resolve();
      } else if (session.exited) {
        settled = true;
        clearTimeout(timer);
        clearInterval(poll);
        reject(ptyError("PTY_ALLOC_FAILED", `pty allocation failed: ${session.startError || "helper exited before reporting readiness"}`));
      }
    }, 10);
    poll.unref();
  }).catch(async (error) => {
    // Close the helper's stdin first and give it a moment to tear itself down.
    //
    // SIGKILLing the helper skipped its own teardown('parent_gone'), the only code
    // that TERM/KILLs the leader group — and on this path leaderPid is usually still
    // null, so killProcessGroup refuses as well. The forked child was then orphaned
    // to pid 1, absent from bridge_status, and had no job metadata for disable.sh:
    // an unrestricted process with no reclaim path anywhere.
    try { session.child?.stdin?.end(); } catch {}
    {
      const deadline = Date.now() + 2000;
      while (session.child && session.child.exitCode === null && Date.now() < deadline) {
        await new Promise((r) => setTimeout(r, 50));
      }
    }
    // Bounded fallback: still SIGKILLs whatever the helper did not reclaim.
    killPtySession(session, "start_failed");
    ptySessions.delete(id);
    syncPtyTimers();
    throw error;
  });

  // Written for scripts/disable.sh, never read back. The reclaimer's discovery
  // loop is entirely field-driven, so the same shape shell_start writes makes pty
  // sessions reclaimable with no change to the script. startedAt MUST be nowIso():
  // disable.sh parses it with `date -j -u -f '%Y-%m-%dT%H:%M:%S'` and silently
  // skips any entry it cannot parse, which would let it print "Disabled" having
  // signalled nothing.
  //
  // Failing closed if the write fails: a live session the reclaimer cannot see is
  // exactly the "invisible to disable.sh" hole this metadata exists to close, and
  // shell_exec already demonstrates how that ends.
  try {
    await ptyRuntime.writeJobMetadata({
      id,
      kind: "pty",
      label,
      pid: session.leaderPid,
      processGroupId: session.leaderPid,
      command: `${resolved} ${args.join(" ")}`.trim(),
      cwd,
      startedAt: nowIso(),
      helperPid: session.helperPid,
      pts: session.pts,
      stdoutPath: null,
      stderrPath: null,
    });
  } catch (error) {
    killPtySession(session, "metadata_write_failed");
    ptySessions.delete(id);
    syncPtyTimers();
    throw ptyError("PTY_METADATA_FAILED", `pty session could not be recorded for the reclaimer (${error?.code || error}); the session was terminated rather than left untracked`);
  }
  // First membership record, while the helper certainly owns the device. Kept
  // fresh from pty_read/pty_write and from the 5s sweeper, because after the
  // session ends the terminal is revoked and cannot be scanned at all.
  refreshPtyTtyTargets(session);
  return session;
}

// Synchronous, because every caller is between a revocation decision and
// process.exit. An await here is a window in which the bridge dies with the pty
// still alive.
function killPtySession(session, reason, { startBudget = true } = {}) {
  if (startBudget) beginPtyTtyScanBudget();
  const result = {
    sessionId: session.id,
    reason,
    leaderGroupKilled: false,
    leaderGroupError: null,
    helperKilled: false,
  };
  // Last chance to see the terminal's membership while the helper still owns the
  // device. pty_close snapshots again before its graceful SIGTERM, because by the
  // time the grace period ends the leader — and with it the helper — is usually
  // gone and the device with it.
  snapshotPtyTtyProcesses(session);
  if (session.leaderPid) {
    // The leader group FIRST, and never -helperPid: measured, kill(-helperPid, 0)
    // is ESRCH because the helper never calls setsid(), so a reclaim path written
    // that way silently no-ops while reporting success.
    const error = killProcessGroup(session.leaderPid, "SIGKILL");
    if (error === null) result.leaderGroupKilled = true;
    else result.leaderGroupError = error;
  } else {
    result.leaderGroupError = "NO_LEADER";
  }
  // Then everything still holding this session's controlling terminal — the
  // background jobs job control put in their own process groups, which the group
  // kill above cannot reach. Both steps run BEFORE the helper is killed, while
  // its master fd still guarantees the device is ours.
  killPtyTtyStragglers(session, result);
  try {
    session.child.kill("SIGKILL");
    result.helperKilled = true;
  } catch (error) {
    result.helperError = error?.code || String(error?.message || error);
  }
  session.closed = true;
  session.closeReason = session.closeReason || reason;
  markPtyExited(session);
  return result;
}

// The killInFlightCommands() analogue: revocation and every exit path call this.
function killPtySessions(reason = "revoked") {
  beginPtyTtyScanBudget();
  const results = [];
  for (const session of ptySessions.values()) {
    if (session.closed && session.exited) continue;
    // One budget for the whole sweep, not one per session.
    results.push(killPtySession(session, reason, { startBudget: false }));
  }
  return results;
}

function signalName(number) {
  const names = { 1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 9: "SIGKILL", 13: "SIGPIPE", 15: "SIGTERM", 19: "SIGSTOP", 20: "SIGTSTP" };
  if (!number) return null;
  return names[number] || `SIG${number}`;
}

// Both intervals exist only while a session does, and both are unref'd. A
// referenced interval would keep bridge.mjs alive after rl 'close' — an
// unrestricted bridge with no client and nothing watching it, which is the worst
// possible residue.
function syncPtyTimers() {
  const live = livePtySessions().length;
  if (live > 0) {
    if (!ptySweeper) {
      ptySweeper = setInterval(sweepPtySessions, PTY_SWEEP_MS);
      ptySweeper.unref();
    }
  } else if (ptySweeper) {
    clearInterval(ptySweeper);
    ptySweeper = null;
  }
}

function sweepPtySessions() {
  const now = Date.now();
  for (const session of livePtySessions()) {
    // Covers the session nobody is reading from: a job backgrounded at a prompt
    // and then left alone is still recorded, within PTY_SWEEP_MS, while the
    // terminal can still be scanned. That window is the residual exposure — a job
    // started AND its session ended inside the same interval, with no pty_read or
    // pty_write in between, is not in the record and survives.
    refreshPtyTtyTargets(session);
    if (now - session.lastActivityAt > session.idleTimeoutMs) {
      stderr(`pty session ${session.id} idle for ${now - session.lastActivityAt}ms; reclaiming.`);
      session.closeReason = "idle_timeout";
      killPtySession(session, "idle_timeout");
    } else if (now - session.createdAt > PTY_MAX_LIFETIME_MS) {
      stderr(`pty session ${session.id} exceeded the ${PTY_MAX_LIFETIME_MS}ms lifetime ceiling; reclaiming.`);
      session.closeReason = "max_lifetime";
      killPtySession(session, "max_lifetime");
    }
  }
}

// One shared teardown for the three immediate-exit handlers. Without it, SIGTERM —
// exactly what scripts/disable.sh sends — reclaimed bridge.mjs and printed its
export const PTY_TOOLS = [
{
    name: "pty_start",
    title: "Start interactive pty session",
    description: "Start a program on a real pseudo-terminal and keep it running as a session that can be written to, read from, resized, and signalled. Use this for anything that prompts or redraws: interactive authentication, sudo and ssh passphrase prompts, REPLs, test watchers, git rebase, and full-screen TUIs. 'command' plus 'args' is an argv vector, not a shell string; for a shell use command '/bin/zsh' with args ['-i']. Sessions are in memory only and do not survive a bridge restart. Removing the full-access unlock file terminates every live session.",
    inputSchema: {
      type: "object",
      properties: {
        command: { type: "string", minLength: 1, description: "Executable to run. Absolute path, or a name resolved through PATH." },
        args: { type: "array", items: { type: "string" }, maxItems: 256, description: "Argument vector. Not parsed by a shell." },
        cwd: { type: "string", description: "Working directory. Supports absolute, relative, and ~/ paths. Defaults to the user's home directory." },
        env: { type: "object", additionalProperties: { type: ["string", "number", "boolean", "null"] }, maxProperties: 64, description: "Environment overrides. Set a value to null to remove it." },
        cols: { type: "integer", minimum: 20, maximum: 500, default: 120 },
        rows: { type: "integer", minimum: 5, maximum: 200, default: 30 },
        term: { type: "string", enum: ["xterm-256color", "xterm", "vt100", "dumb"], default: "xterm-256color", description: "TERM for the child. Programs that call tput fail outright without it." },
        idle_timeout_ms: { type: "integer", minimum: 30000, maximum: 3600000, default: 900000, description: "Session is reclaimed after this long with no pty tool call against it. Output from the child does not count as activity." },
        label: { type: "string", maxLength: 100 },
      },
      required: ["command"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true },
  },
{
    name: "pty_read",
    title: "Read pty session output",
    description: "Read a byte range of a session's output. 'cursor' is an absolute byte offset, so the same cursor always returns the same bytes and 'next_cursor' continues without gap or overlap; a retried read never loses output. Reading a session that has already exited is not an error and is how final output is collected. ANSI escapes and carriage-return progress redraws are removed by default; disable both to see raw TUI bytes.",
    inputSchema: {
      type: "object",
      properties: {
        session_id: { type: "string", minLength: 1, maxLength: 128 },
        cursor: { type: "integer", minimum: 0, default: 0, description: "Absolute byte offset. Start at 0, then pass the previous next_cursor." },
        max_bytes: { type: "integer", minimum: 1024, maximum: 1000000, default: 65536 },
        strip_ansi: { type: "boolean", default: true },
        collapse_carriage_returns: { type: "boolean", default: true },
        wait_ms: { type: "integer", minimum: 0, maximum: 30000, default: 0, description: "Wait up to this long for new output before returning. 0 returns immediately." },
      },
      required: ["session_id"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
{
    name: "pty_write",
    title: "Write to pty session",
    description: "Send bytes to the session's terminal exactly as typed. End a line with \\r to submit it. Control characters: \\u0003 is Ctrl-C (interrupts only the foreground program), \\u0004 is end-of-file, \\u001a is Ctrl-Z, \\u001b is Escape. Input is never echoed back by this tool; read it with pty_read. The written bytes are never recorded in the audit log, so passphrase prompts are safe to answer here. Line length limit: while the terminal is in canonical mode (the default, and what every interactive prompt uses), the line discipline DISCARDS an entire input line of 1024 bytes or more rather than truncating it, so a write that would build such a line is refused with PTY_WRITE_CANON_LIMIT instead of being reported as delivered. Bytes accumulate across calls until a \\r or \\n, so chunking a long line does not evade it. Send lines of at most 1023 bytes.",
    inputSchema: {
      type: "object",
      properties: {
        session_id: { type: "string", minLength: 1, maxLength: 128 },
        data: { type: "string", maxLength: 65536 },
      },
      required: ["session_id", "data"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true },
  },
{
    name: "pty_resize",
    title: "Resize pty session",
    description: "Change the terminal window size and deliver SIGWINCH to the session, so full-screen programs redraw at the new geometry. The returned cols and rows are the kernel's own read-back of the window size, not the requested values; a resize that cannot be confirmed is reported as an error rather than as success.",
    inputSchema: {
      type: "object",
      properties: {
        session_id: { type: "string", minLength: 1, maxLength: 128 },
        cols: { type: "integer", minimum: 20, maximum: 500 },
        rows: { type: "integer", minimum: 5, maximum: 200 },
      },
      required: ["session_id", "cols", "rows"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
{
    name: "pty_signal",
    title: "Signal pty session",
    description: "Send a signal to the session's entire process group, which includes the shell itself and every program it started. To interrupt only the foreground program and keep the shell alive, use pty_write with \\u0003 instead. Signals are delivered by the pty helper to the session leader's group; the result reports whether delivery was confirmed.",
    inputSchema: {
      type: "object",
      properties: {
        session_id: { type: "string", minLength: 1, maxLength: 128 },
        signal: { type: "string", enum: ["INT", "TERM", "KILL", "HUP", "QUIT", "USR1", "USR2", "WINCH", "TSTP", "CONT"] },
      },
      required: ["session_id", "signal"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false },
  },
{
    name: "pty_close",
    title: "Close pty session",
    description: "End a session and reclaim it. Sends SIGTERM, waits for the grace period, then SIGKILL to the leader's process group, then SIGKILL to anything still holding the session's controlling terminal (interactive job control puts every background job — a plain 'cmd &' — in its own process group, which a group kill does not reach; those pids are listed in 'ttyProcessesKilled'). 'leaderGroupGone' reports the group check alone. 'containment_verified' is true only when the group is gone AND nothing that shared the terminal survived; survivors are listed in 'uncontainedPids'. It can legitimately be false: a descendant that both called setsid() and detached from the terminal escapes both kills. Idempotent: closing an already-closed session reports its recorded outcome.",
    inputSchema: {
      type: "object",
      properties: {
        session_id: { type: "string", minLength: 1, maxLength: 128 },
        force: { type: "boolean", default: false, description: "Skip SIGTERM and the grace period." },
        grace_ms: { type: "integer", minimum: 0, maximum: 10000, default: 2000 },
      },
      required: ["session_id"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false },
  }
];

export async function handlePty(name, args, context) {
  const { HOME, requireString, optionalString, optionalStringArray, optionalInteger, optionalBoolean, normalizeEnv, audit, resolvePath } = context;
  switch (name) {
        case "pty_start": {
          const command = requireString(args, "command");
          // Every argument re-validated by hand and clamped to the same bounds the
          // schema advertises: the schema is a hint to the client, not an enforcement
          // boundary, and this endpoint is publicly reachable.
          const argv = optionalStringArray(args, "args", []);
          if (argv.length > 256) throw new Error("'args' must contain at most 256 entries");
          const cwd = resolvePath(optionalString(args, "cwd", HOME));
          const env = normalizeEnv(args?.env);
          if (Object.keys(env).length > 64) throw new Error("'env' must contain at most 64 properties");
          const cols = optionalInteger(args, "cols", 120, 20, 500);
          const rows = optionalInteger(args, "rows", 30, 5, 200);
          const term = optionalString(args, "term", "xterm-256color");
          if (!PTY_TERMS.includes(term)) throw new Error(`'term' must be one of ${PTY_TERMS.join(", ")}`);
          // Clamp to the operator's configured window. The schema range is the absolute
          // bound; PTY_IDLE_TIMEOUT_MS is the operator's policy, and a request may only
          // shorten it. Without the min(), a model could ask for an hour against a
          // 60-second reclaim setting and hold a live pty 60x longer than configured —
          // README already documents the intended behaviour as "may request less".
          const idleTimeoutMs = Math.min(
            PTY_IDLE_TIMEOUT_MS,
            optionalInteger(args, "idle_timeout_ms", PTY_IDLE_TIMEOUT_MS, 30_000, 3_600_000),
          );
          const label = optionalString(args, "label", path.basename(command)).replace(/[^A-Za-z0-9._-]+/g, "-").slice(0, 80) || "pty";
          try {
            const session = await startPtySession({ command, args: argv, cwd, env, cols, rows, term, idleTimeoutMs, label });
            const result = {
              sessionId: session.id,
              leaderPid: session.leaderPid,
              helperPid: session.helperPid,
              pts: session.pts,
              cols: session.cols,
              rows: session.rows,
              term,
              cwd,
              command: session.command,
              args: argv,
              idleTimeoutMs,
              startedAt: new Date(session.createdAt).toISOString(),
              cursor: 0,
            };
            await audit(name, args, { sessionId: session.id, leaderPid: session.leaderPid, pts: session.pts, command: session.command });
            return result;
          } catch (error) {
            await audit(name, args, { code: error?.code || null }, error);
            throw error;
          }
        }
    
        case "pty_read": {
          const sessionId = requirePtySessionId(args);
          const cursor = optionalInteger(args, "cursor", 0, 0, Number.MAX_SAFE_INTEGER);
          const maxBytes = optionalInteger(args, "max_bytes", 65_536, 1_024, 1_000_000);
          const stripAnsi = optionalBoolean(args, "strip_ansi", true);
          const collapseCarriageReturns = optionalBoolean(args, "collapse_carriage_returns", true);
          const waitMs = optionalInteger(args, "wait_ms", 0, 0, 30_000);
          // Reading an exited session is deliberately not an error: its final output is
          // the most valuable thing it produced.
          const session = getPtySession(sessionId);
          // Throttled to at most one ps per PTY_TTY_REFRESH_MS per session, so a
          // polling reader does not put a fork in its own loop.
          refreshPtyTtyTargets(session);
          if (waitMs > 0 && session.ring.total <= cursor && !session.exited) await waitForPtyOutput(session, waitMs);
          const slice = ptySliceForCursor(session, cursor, maxBytes);
          // Measured before the read is recorded, so it answers "how long had this
          // session been unattended" rather than always answering zero.
          const idleMs = Date.now() - session.lastActivityAt;
          session.lastActivityAt = Date.now();
          session.lastReadAt = session.lastActivityAt;
          const result = {
            sessionId,
            cursor,
            nextCursor: slice.nextCursor,
            text: renderPtyText(slice.bytes, { stripAnsi, collapseCarriageReturns }),
            lostBytes: slice.lostBytes,
            truncated: slice.truncated,
            totalBytes: slice.totalBytes,
            retainedBytes: slice.retainedBytes,
            exited: session.exited,
            exitCode: session.exitCode,
            exitSignal: session.exitSignal,
            closeReason: session.closeReason,
            cols: session.cols,
            rows: session.rows,
            idleMs,
          };
          // Byte counts and offsets only. The transcript itself is never audited: it
          // contains everything typed at a prompt, including what a no-echo prompt
          // deliberately kept off the screen.
          await audit(name, args, {
            sessionId,
            cursor,
            nextCursor: result.nextCursor,
            returnedBytes: slice.bytes.length,
            lostBytes: slice.lostBytes,
            exited: session.exited,
          });
          return result;
        }
    
        case "pty_write": {
          const sessionId = requirePtySessionId(args);
          const data = requireString(args, "data", { allowEmpty: true });
          const session = getPtySession(sessionId);
          const payload = Buffer.from(data, "utf8");
          if (payload.length > PTY_WRITE_MAX) {
            throw ptyError("PTY_WRITE_TOO_LARGE", `'data' is ${payload.length} bytes; the limit is ${PTY_WRITE_MAX}`);
          }
          if (session.exited) throw ptyError("PTY_EXITED", `pty session '${sessionId}' has finished (exitCode=${session.exitCode}, exitSignal=${session.exitSignal}); start a new session with pty_start`);
          // Same throttle as pty_read. A write is usually what CREATES a new process
          // force: a write is the ONLY operation that can create a terminal member, so this
          // scan must not be throttled away. Deferring it to "the next call" meant a job
          // backgrounded and abandoned in the same breath was never recorded at all.
          refreshPtyTtyTargets(session, { force: true });
          const stdin = session.child.stdin;
          if (!stdin.writable || stdin.destroyed) throw ptyError("PTY_EXITED", `pty session '${sessionId}' is no longer accepting input`);
          // Refused rather than queued: an unbounded outbound buffer on a public
          // endpoint is the same memory-exhaustion vector as an unbounded ring.
          if (stdin.writableLength > PTY_WRITE_MAX) {
            throw ptyError("PTY_WRITE_BLOCKED", `pty session '${sessionId}' already has ${stdin.writableLength} bytes of unread input; retry once the program consumes it`);
          }
          // A byte count measured at a pipe is not a report about the program.
          //
          // In canonical mode the Darwin line discipline DISCARDS a whole line at or
          // over MAX_CANON (1024) — it does not truncate it. Measured on the shipped
          // code: 1023 bytes arrived intact; 1024, 2000, 4096, 20000 and 65000 all
          // arrived as literally nothing while pty_write returned the full
          // bytesWritten. Splitting the same line into 200-byte chunks failed
          // identically, because the limit is on the line the discipline is
          // assembling, not on the write. Canonical mode is the default for every
          // session and for every interactive prompt this tool exists to drive, so
          // that path silently ate SSH keys, commit bodies and base64 blobs.
          //
          // The mode is only knowable from inside the session (`stty raw` is
          // invisible from out here), so the helper is asked — but only when the
          // payload actually contains an over-long line. Ordinary typing costs no
          // extra round trip.
          const runs = canonicalRuns(payload);
          // MAX_CANON applies to the line the discipline is ASSEMBLING, not to one
          // write, so bytes carried over from earlier writes count. Measured: the same
          // over-long line sent as 200-byte chunks was discarded exactly as the single
          // write was.
          const longestLineRun = Math.max(session.canonPendingBytes + runs.first, runs.longest);
          let canonical = null;
          if (longestLineRun >= PTY_MAX_CANON) {
            let termios;
            try {
              termios = await sendPtyControl(session, "termios", { op: "termios" }, PTY_ACK_TIMEOUT_MS);
            } catch (error) {
              // A session that ended while we were asking is an exited session, not an
              // unreadable mode. Reporting it as the latter would send the caller
              // looking for a terminal problem that no longer exists.
              if (error?.code === "PTY_EXITED") throw error;
              throw ptyError(
                "PTY_WRITE_MODE_UNKNOWN",
                `this write would make the terminal's current input line ${longestLineRun} bytes, at or over the ${PTY_MAX_CANON}-byte MAX_CANON limit at which a canonical-mode line discipline discards the line entirely. The mode could not be read back (${error?.message || error}), so the write was refused rather than reported as delivered. Send lines of at most ${PTY_MAX_CANON - 1} bytes.`,
              );
            }
            // ok:0 is the helper reporting that POSIX::Termios->getattr FAILED. It
            // still sends icanon:0 alongside it, and reading that as "raw mode" reads
            // a failed measurement as a measurement of raw — so the over-long line was
            // written and reported delivered, which is the precise outcome
            // PTY_WRITE_CANON_LIMIT exists to prevent. PTY_WRITE_MODE_UNKNOWN
            // previously covered only a rejected promise: a timeout or a closed pipe,
            // never an answer that says "I could not read it".
            //
            // Not hypothetical: measured on this machine, once the session leader
            // exits Darwin revoke()s the controlling terminal and getattr on the
            // helper's own slave fd fails with ENOTTY, producing exactly this reply.
            if (termios.ok !== 1 && termios.ok !== true) {
              throw ptyError(
                "PTY_WRITE_MODE_UNKNOWN",
                `this write would make the terminal's current input line ${longestLineRun} bytes, at or over the ${PTY_MAX_CANON}-byte MAX_CANON limit at which a canonical-mode line discipline discards the line entirely. The helper could not read the line discipline's state back from the kernel (termios getattr failed), so the mode is unknown and the write was refused rather than reported as delivered. Send lines of at most ${PTY_MAX_CANON - 1} bytes.`,
              );
            }
            canonical = termios.icanon === 1 || termios.icanon === true;
            if (canonical) {
              throw ptyError(
                "PTY_WRITE_CANON_LIMIT",
                `this write would make the terminal's current input line ${longestLineRun} bytes with no \\r or \\n, and the session is in canonical mode, where the line discipline DISCARDS any line of ${PTY_MAX_CANON} bytes or more rather than truncating it — the program would receive none of it. Send lines of at most ${PTY_MAX_CANON - 1} bytes, or have the program put the terminal in raw mode first.`,
              );
            }
            // Raw mode has no canonical line buffer, so the carry-over is meaningless
            // and must not accumulate into a probe on every subsequent keystroke.
            session.canonPendingBytes = 0;
          }
          stdin.write(payload);
          // In raw mode there is no canonical line being assembled, so nothing carries
          // over — otherwise a TUI session would re-probe on every keystroke once its
          // running total passed MAX_CANON.
          session.canonPendingBytes = canonical === false
            ? 0
            : (runs.hasTerminator ? runs.trailing : session.canonPendingBytes + payload.length);
          session.lastActivityAt = Date.now();
          const result = {
            sessionId,
            bytesWritten: payload.length,
            // Honest about what was actually established. null means "not checked":
            // every line this write touches is comfortably under MAX_CANON, so the
            // mode does not change the outcome.
            canonicalMode: canonical,
            pendingLineBytes: longestLineRun,
          };
          await audit(name, args, result);
          return result;
        }
    
        case "pty_resize": {
          const sessionId = requirePtySessionId(args);
          const cols = optionalInteger(args, "cols", undefined, 20, 500);
          const rows = optionalInteger(args, "rows", undefined, 5, 200);
          if (cols === undefined || rows === undefined) throw new Error("'cols' and 'rows' are required");
          const session = getPtySession(sessionId);
          if (session.exited) throw ptyError("PTY_EXITED", `pty session '${sessionId}' has finished; nothing to resize`);
          const event = await sendPtyControl(session, "resize", { op: "resize", cols, rows }, PTY_ACK_TIMEOUT_MS);
          session.lastActivityAt = Date.now();
          const ok = (event.ok === 1 || event.ok === true) && event.confirmed === 1 && event.cols === cols && event.rows === rows;
          if (!ok) {
            // Never report a resize that the kernel did not confirm. A pty_resize that
            // echoes the requested numbers is indistinguishable from one that did
            // nothing, which is exactly the failure that ruled out script(1).
            throw ptyError("PTY_RESIZE_UNCONFIRMED", `resize to ${cols}x${rows} was not confirmed; the kernel reports ${event.cols}x${event.rows}`);
          }
          const result = { sessionId, ok: true, cols: event.cols, rows: event.rows };
          await audit(name, args, result);
          return result;
        }
    
        case "pty_signal": {
          const sessionId = requirePtySessionId(args);
          const signal = requireString(args, "signal");
          // Validated against the enum here, not just in the schema. shell_job_kill
          // hands its signal straight to process.kill; that is survivable for a fixed
          // four-value enum, but this list is longer and the target is a process group.
          if (!PTY_SIGNALS.includes(signal)) {
            throw ptyError("PTY_SIGNAL_NOT_ALLOWED", `'signal' must be one of ${PTY_SIGNALS.join(", ")}`);
          }
          const session = getPtySession(sessionId);
          if (session.exited) throw ptyError("PTY_EXITED", `pty session '${sessionId}' has finished; nothing to signal`);
          const event = await sendPtyControl(session, "signal", { op: "signal", sig: signal }, PTY_ACK_TIMEOUT_MS);
          session.lastActivityAt = Date.now();
          const result = {
            sessionId,
            delivered: event.delivered === 1 || event.delivered === true,
            signal,
            targetProcessGroup: session.leaderPid,
            note: "Delivered to the whole process group. Use pty_write with \\u0003 to interrupt only the foreground program.",
          };
          if (!result.delivered) throw ptyError("PTY_SIGNAL_UNCONFIRMED", `pty helper could not deliver ${signal} to process group ${session.leaderPid}`);
          await audit(name, args, result);
          return result;
        }
    
        case "pty_close": {
          const sessionId = requirePtySessionId(args);
          const force = optionalBoolean(args, "force", false);
          const graceMs = optionalInteger(args, "grace_ms", PTY_CLOSE_GRACE_MS, 0, 10_000);
          const session = getPtySession(sessionId);
          const reason = session.closeReason || (force ? "force_closed" : "closed");
          // Before the SIGTERM, not after: the graceful path usually ends with the
          // leader AND the helper gone, and once the helper releases the master fd
          // /dev/ttysNNN can belong to somebody else, so it can no longer be scanned
          // safely. Recorded here with each process's start time, and re-verified
          // against it before anything is signalled.
          beginPtyTtyScanBudget();
          snapshotPtyTtyProcesses(session);
          if (!force && !session.exited) {
            try {
              await sendPtyControl(session, "signal", { op: "signal", sig: "TERM" }, PTY_ACK_TIMEOUT_MS).catch(() => {});
            } catch {}
            const deadline = Date.now() + graceMs;
            while (Date.now() < deadline && !session.exited) await new Promise((r) => setTimeout(r, 25));
          }
          // A fresh budget: the grace period above may have consumed the first one,
          // and this is an interactive close, not the exit path.
          const killed = killPtySession(session, reason);
          // Bounded retry because a SIGKILLed leader stays visible as a zombie until
          // it is reaped. Allowed to come back false: a grandchild that called
          // setsid() AND redirected away from the terminal escapes both the group kill
          // and the tty sweep, exactly as shell_start does, and saying so is better
          // than claiming containment.
          const containment = await verifyPtyContainment(session, 1_000);
          // Pruned on a clean close, kept on a crash: this file is a tombstone for
          // scripts/disable.sh and never read back to resume anything, so leaving it
          // behind after an orderly close would only accumulate entries that name a
          // process group that no longer exists.
          await fsp.rm(session.metadataPath, { force: true }).catch(() => {});
          syncPtyTimers();
          const result = {
            sessionId,
            reason,
            leaderGroupKilled: killed.leaderGroupKilled,
            leaderGroupError: killed.leaderGroupError,
            helperKilled: killed.helperKilled,
            leaderGroupGone: containment.leaderGroupGone,
            // Processes that were sharing the session's controlling terminal but not
            // its process group — the ordinary `cmd &` case — killed individually.
            ttyProcessesKilled: killed.ttyProcessesKilled,
            // Recorded on this terminal earlier, but the pid is somebody else's
            // process now, so it was deliberately NOT signalled.
            ttyRecycledSkipped: killed.ttyRecycledSkipped,
            // True only when the leader group is gone AND nothing that shared the
            // terminal survived. It is not a claim about a descendant that both
            // called setsid() and detached from the tty.
            containmentVerified: containment.contained,
            uncontainedPids: containment.survivors,
            exitCode: session.exitCode,
            exitSignal: session.exitSignal,
            totalBytes: session.ring.total,
          };
          await audit(name, args, result);
          return result;
        }
    default: throw new Error("Unknown pty tool: " + name);
  }
}
