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
    const parsed = parseResponse(text, response.headers.get("content-type") || "");
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
