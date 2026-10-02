#!/usr/bin/env node
import fs from "node:fs";
import readline from "node:readline";

const UPSTREAM = process.env.NEOY_UPSTREAM || "http://127.0.0.1:6767/mcp";
const TOKEN_FILE = process.env.NEOY_TOKEN_FILE || ((process.env.HOME || "") + "/Library/Application Support/NeoY/core-token");
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

async function forward(msg) {
  const hasID = Object.prototype.hasOwnProperty.call(msg, "id");
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
      process.stdout.write(JSON.stringify({
        jsonrpc: "2.0",
        id: msg.id ?? null,
        error: { code: -32603, message: "NeoY upstream HTTP " + response.status }
      }) + "\n");
      return;
    }
    const parsed = parseResponse(text, response.headers.get("content-type") || "");
    process.stdout.write(JSON.stringify(parsed) + "\n");
  } catch (error) {
    if (!hasID) return;
    process.stdout.write(JSON.stringify({
      jsonrpc: "2.0",
      id: msg.id ?? null,
      error: { code: -32603, message: "NeoY upstream failed: " + error.message }
    }) + "\n");
  }
}

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on("line", (line) => {
  if (!line.trim()) return;
  let msg;
  try { msg = JSON.parse(line); } catch { return; }
  void forward(msg);
});
