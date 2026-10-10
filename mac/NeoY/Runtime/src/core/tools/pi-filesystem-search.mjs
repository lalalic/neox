// Search behavior adapted from @mariozechner/pi-coding-agent 0.73.1 grep/find tools.
import { createInterface } from "node:readline";
import path from "node:path";
import { appendWithinByteLimit, ensurePiNativeTool, truncatePiLine } from "./pi-filesystem-utils.mjs";

function runLines(command, argv, { timeoutMs, onLine, allowExitOne = false }) {
  return new Promise((resolve, reject) => {
    const child = command.spawn(command.path, argv, { stdio: ["ignore", "pipe", "pipe"] });
    const rl = createInterface({ input: child.stdout, crlfDelay: Infinity });
    let stderr = "";
    let timedOut = false;
    const timer = setTimeout(() => { timedOut = true; child.kill("SIGTERM"); }, timeoutMs);
    child.stderr.on("data", (chunk) => { stderr += chunk.toString(); });
    rl.on("line", (line) => onLine(line, child));
    child.on("error", (error) => { clearTimeout(timer); rl.close(); reject(error); });
    child.on("close", (code) => {
      clearTimeout(timer); rl.close();
      if (timedOut) return reject(new Error(`filesystem search timed out after ${timeoutMs}ms`));
      if (code !== 0 && !(allowExitOne && code === 1) && !child.killed) return reject(new Error(stderr.trim() || `${command.path} exited with ${code}`));
      resolve({ code, stderr, killed: child.killed });
    });
  });
}

export async function piGrep(args, context) {
  const { resolvePath, spawn, toolsDir } = context;
  const root = resolvePath(args.path || ".");
  const rg = await ensurePiNativeTool("rg", toolsDir);
  const maxResults = Math.max(1, Math.min(args.max_results ?? 100, 5000));
  const timeoutMs = Math.max(1000, Math.min(args.timeout_ms ?? 60_000, 120_000));
  const argv = ["--json", "--line-number", "--color=never", "--hidden", "--no-require-git"];
  if (args.ignore_case) argv.push("--ignore-case");
  if (args.literal) argv.push("--fixed-strings");
  if (args.glob) argv.push("--glob", args.glob);
  argv.push("--", args.pattern, root);

  const matches = [];
  const bytes = { value: 0 };
  let resultLimitReached = false;
  let byteLimitReached = false;
  let linesTruncated = false;
  await runLines({ path: rg, spawn }, argv, {
    timeoutMs,
    allowExitOne: true,
    onLine(line, child) {
      if (resultLimitReached || byteLimitReached) return;
      let event;
      try { event = JSON.parse(line); } catch { return; }
      if (event.type !== "match") return;
      const filePath = event.data?.path?.text;
      const lineNumber = event.data?.line_number;
      if (!filePath || !Number.isInteger(lineNumber)) return;
      const raw = String(event.data?.lines?.text || "").replace(/\r?\n$/, "").replace(/\r/g, "");
      const clipped = truncatePiLine(raw);
      linesTruncated ||= clipped.truncated;
      const relative = path.relative(root, filePath) || path.basename(filePath);
      const item = { path: relative.replace(/\\/g, "/"), line: lineNumber, text: clipped.text };
      if (!appendWithinByteLimit(matches, item, bytes)) {
        byteLimitReached = true;
        child.kill("SIGTERM");
        return;
      }
      if (matches.length >= maxResults) {
        resultLimitReached = true;
        child.kill("SIGTERM");
      }
    },
  });
  return { root, matches, count: matches.length, truncated: resultLimitReached || byteLimitReached || linesTruncated, resultLimitReached, byteLimitReached, linesTruncated };
}

export async function piFind(args, context) {
  const { resolvePath, spawn, toolsDir } = context;
  const root = resolvePath(args.path || ".");
  const fd = await ensurePiNativeTool("fd", toolsDir);
  const maxResults = Math.max(1, Math.min(args.max_results ?? 500, 10_000));
  const timeoutMs = Math.max(1000, Math.min(args.timeout_ms ?? 60_000, 120_000));
  const argv = ["--glob", "--color=never", "--hidden", "--no-require-git", "--max-results", String(maxResults)];
  let pattern = args.pattern;
  if (pattern.includes("/")) {
    argv.push("--full-path");
    if (!pattern.startsWith("/") && !pattern.startsWith("**/") && pattern !== "**") pattern = `**/${pattern}`;
  }
  argv.push("--", pattern, root);

  const paths = [];
  const bytes = { value: 0 };
  let byteLimitReached = false;
  await runLines({ path: fd, spawn }, argv, {
    timeoutMs,
    onLine(line, child) {
      if (byteLimitReached) return;
      const raw = line.replace(/\r$/, "").trim();
      if (!raw) return;
      let relative = raw.startsWith(root) ? raw.slice(root.length).replace(/^[/\\]/, "") : path.relative(root, raw);
      relative = relative.replace(/\\/g, "/");
      if (!appendWithinByteLimit(paths, relative, bytes)) {
        byteLimitReached = true;
        child.kill("SIGTERM");
      }
    },
  });
  return { root, paths, count: paths.length, truncated: paths.length >= maxResults || byteLimitReached, resultLimitReached: paths.length >= maxResults, byteLimitReached };
}
