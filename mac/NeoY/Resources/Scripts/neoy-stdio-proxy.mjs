#!/usr/bin/env node
import fs from "node:fs";
import readline from "node:readline";

const UPSTREAM = process.env.NEOY_UPSTREAM || "http://127.0.0.1:6767/mcp";
const TOKEN_FILE = process.env.NEOY_TOKEN_FILE || ((process.env.HOME || "") + "/Library/Application Support/NeoY/core-token");
const MODERN_PROTOCOL = "2026-07-28";
const SERVER_INFO = {
  name: "NeoY",
  title: "neo",
  version: "2.3.0",
  description: "Privileged NeoY runtime for the host Mac."
};
const SECURITY_SCHEMES = [{ type: "oauth2", scopes: ["mcp"] }];

let token = "";
try {
  token = fs.readFileSync(TOKEN_FILE, "utf8").trim();
} catch (error) {
  process.stderr.write("NeoY proxy cannot read token file: " + error.message + "\n");
  process.exit(78);
}
if (!token) {
  process.stderr.write("NeoY proxy token file is empty\n");
  process.exit(78);
}

function parseResponse(text, contentType) {
  if (contentType.includes("text/event-stream")) {
    for (const line of text.split(/\r?\n/)) {
      if (line.startsWith("data:")) {
        const payload = line.slice(5).trim();
        if (payload) return JSON.parse(payload);
      }
    }
    throw new Error("upstream SSE response had no data frame");
  }
  return JSON.parse(text);
}

function modernRequest(msg) {
  return msg && msg.params && msg.params._meta &&
    msg.params._meta["io.modelcontextprotocol/protocolVersion"] === MODERN_PROTOCOL;
}

function completeModern(result) {
  const base = result && typeof result === "object" ? result : {};
  return {
    resultType: "complete",
    ...base,
    _meta: {
      ...(base._meta || {}),
      "io.modelcontextprotocol/serverInfo": SERVER_INFO
    }
  };
}

function titleFromName(name) {
  return String(name || "Neo tool")
    .split(/[._-]+/)
    .filter(Boolean)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ");
}

function normalizeSchema(value) {
  if (Array.isArray(value)) return value.map(normalizeSchema);
  if (!value || typeof value !== "object") return value;

  const out = {};
  for (const [key, raw] of Object.entries(value)) {
    let v = normalizeSchema(raw);

    if (
      ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
       "minLength", "maxLength", "minItems", "maxItems", "minProperties", "maxProperties"].includes(key)
      && typeof v === "boolean"
    ) {
      v = v ? 1 : 0;
    }

    if (key === "const" && typeof v === "boolean" && ["integer", "number"].includes(value.type)) {
      v = v ? 1 : 0;
    }

    out[key] = v;
  }
  return out;
}

function normalizeTool(tool) {
  const annotations = {
    readOnlyHint: false,
    destructiveHint: false,
    idempotentHint: false,
    openWorldHint: false,
    ...(tool.annotations || {})
  };

  const meta = {
    ...(tool._meta || {}),
    securitySchemes: SECURITY_SCHEMES
  };

  return {
    ...tool,
    title: tool.title || titleFromName(tool.name),
    inputSchema: normalizeSchema(tool.inputSchema || { type: "object", properties: {} }),
    annotations,
    securitySchemes: SECURITY_SCHEMES,
    _meta: meta
  };
}

function normalizeResultForWeb(msg, parsed) {
  if (!parsed || parsed.error || !parsed.result) return parsed;
  if (msg.method === "tools/list" && Array.isArray(parsed.result.tools)) {
    parsed.result.tools = parsed.result.tools.map(normalizeTool);
  }
  return parsed;
}

function write(message) {
  process.stdout.write(JSON.stringify(message) + "\n");
}

async function forward(msg) {
  const hasID = Object.prototype.hasOwnProperty.call(msg, "id");

  if (msg && msg.method === "server/discover" && hasID) {
    write({
      jsonrpc: "2.0",
      id: msg.id,
      result: {
        resultType: "complete",
        supportedVersions: [MODERN_PROTOCOL, "2025-11-25", "2025-06-18"],
        capabilities: {
          tools: { listChanged: false },
          resources: { listChanged: false, subscribe: false }
        },
        instructions: "NeoY has privileged access as the logged-in macOS user.",
        ttlMs: 3600000,
        cacheScope: "private",
        _meta: { "io.modelcontextprotocol/serverInfo": SERVER_INFO }
      }
    });
    return;
  }

  try {
    const response = await fetch(UPSTREAM, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "accept": "application/json, text/event-stream",
        "authorization": "Bearer " + token,
        "cf-connecting-ip": "127.0.0.1"
      },
      body: JSON.stringify(msg)
    });
    const text = await response.text();
    if (!hasID) return;
    if (!response.ok) {
      write({
        jsonrpc: "2.0",
        id: msg.id ?? null,
        error: { code: -32603, message: "NeoY upstream HTTP " + response.status }
      });
      return;
    }
    let parsed = parseResponse(text, response.headers.get("content-type") || "");
    parsed = normalizeResultForWeb(msg, parsed);
    if (modernRequest(msg) && parsed && !parsed.error && parsed.result && msg.method !== "initialize") {
      parsed.result = completeModern(parsed.result);
    }
    write(parsed);
  } catch (error) {
    if (!hasID) return;
    write({
      jsonrpc: "2.0",
      id: msg.id ?? null,
      error: { code: -32603, message: "NeoY upstream failed: " + error.message }
    });
  }
}

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on("line", (line) => {
  if (!line.trim()) return;
  let msg;
  try { msg = JSON.parse(line); } catch { return; }
  void forward(msg);
});
