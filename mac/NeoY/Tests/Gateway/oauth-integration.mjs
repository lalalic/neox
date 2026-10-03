#!/usr/bin/env node
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const GATEWAY = path.join(ROOT, "Runtime/src/core/gateway.mjs");
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "neoy-oauth-test-"));
const token = "test-static-token-0123456789abcdef";
const redirectUri = "https://chatgpt.com/connector/oauth/test_case";
const verifier = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~abc";
const challenge = crypto.createHash("sha256").update(verifier, "ascii").digest("base64url");
const coreTokenFile = path.join(temp, "core-token");
fs.writeFileSync(coreTokenFile, "core-test-token\n", { mode: 0o600 });

const upstream = http.createServer(async (req, res) => {
  let body = "";
  for await (const chunk of req) body += chunk;
  const msg = JSON.parse(body || "{}");
  let result;
  if (msg.method === "initialize") {
    result = { protocolVersion: "2025-06-18", capabilities: { tools: {} }, serverInfo: { name: "NeoY", version: "test" } };
  } else if (msg.method === "tools/list") {
    result = {
      tools: [
        { name: "shell_exec", description: "Run a command", inputSchema: { type: "object", properties: { command: { type: "string" } } } },
        { name: "phone.media.search", description: "Search media", inputSchema: { type: "object", properties: {} } },
      ],
    };
  } else if (msg.method === "tools/call") {
    result = { content: [{ type: "text", text: "ok:" + msg.params?.name }] };
  } else {
    result = {};
  }
  const payload = JSON.stringify({ jsonrpc: "2.0", id: msg.id ?? null, result });
  res.writeHead(200, { "content-type": "application/json", "content-length": Buffer.byteLength(payload) });
  res.end(payload);
});

function listen(server) {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => resolve(server.address().port));
  });
}

function waitForGateway(child, base) {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + 5000;
    let stderr = "";
    child.stderr.on("data", (d) => { stderr += d; });
    child.once("exit", (code) => reject(new Error("gateway exited " + code + "\n" + stderr)));
    const probe = async () => {
      try {
        const r = await fetch(base + "/.well-known/oauth-protected-resource/mcp");
        if (r.ok) return resolve(stderr);
      } catch {}
      if (Date.now() >= deadline) return reject(new Error("gateway did not start\n" + stderr));
      setTimeout(probe, 50);
    };
    probe();
  });
}

async function bodyJson(response) {
  const text = await response.text();
  return text ? JSON.parse(text) : null;
}

function form(values) {
  return new URLSearchParams(values).toString();
}


let gateway;
function startGateway(gatewayPort, upstreamPort) {
  const child = spawn(process.execPath, [GATEWAY], {
    cwd: ROOT,
    stdio: ["ignore", "ignore", "pipe"],
    env: {
      ...process.env,
      NEOY_HTTP_PORT: String(gatewayPort),
      NEOY_HTTP_TOKEN: token,
      NEOY_PUBLIC_URL: `http://127.0.0.1:${gatewayPort}`,
      NEOY_DATA_DIR: temp,
      NEOY_UPSTREAM: `http://127.0.0.1:${upstreamPort}/mcp`,
      NEOY_TOKEN_FILE: coreTokenFile,
    },
  });
  return child;
}

async function stopGateway(child) {
  if (!child || child.killed) return;
  const exited = new Promise((resolve) => child.once("exit", resolve));
  child.kill("SIGTERM");
  await exited;
}

try {
  const upstreamPort = await listen(upstream);
  const holder = http.createServer();
  const gatewayPort = await listen(holder);
  await new Promise((r) => holder.close(r));
  const base = `http://127.0.0.1:${gatewayPort}`;
  gateway = startGateway(gatewayPort, upstreamPort);
  await waitForGateway(gateway, base);

  const prm = await fetch(base + "/.well-known/oauth-protected-resource/mcp");
  assert.equal(prm.status, 200);
  assert.deepEqual((await bodyJson(prm)).authorization_servers, [base]);

  const as = await fetch(base + "/.well-known/oauth-authorization-server");
  const asBody = await bodyJson(as);
  assert.equal(asBody.issuer, base);
  assert.deepEqual(asBody.code_challenge_methods_supported, ["S256"]);
  assert.deepEqual(asBody.grant_types_supported, ["authorization_code", "refresh_token"]);
  assert.equal(asBody.registration_endpoint, base + "/register");

  const registration = await fetch(base + "/register", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      client_name: "ChatGPT",
      redirect_uris: [redirectUri],
      grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"],
      token_endpoint_auth_method: "none",
    }),
  });
  assert.equal(registration.status, 201);
  const registered = await bodyJson(registration);
  assert.match(registered.client_id, /^neo-dcr-[0-9a-f]{32}$/);
  assert.deepEqual(registered.redirect_uris, [redirectUri]);
  assert.equal(registered.token_endpoint_auth_method, "none");
  const clientId = registered.client_id;

  const repeatRegistration = await fetch(base + "/register", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      client_name: "ChatGPT",
      redirect_uris: [redirectUri],
      grant_types: ["authorization_code"],
      response_types: ["code"],
      token_endpoint_auth_method: "none",
    }),
  });
  assert.equal(repeatRegistration.status, 201);
  assert.equal((await bodyJson(repeatRegistration)).client_id, clientId);

  const rejectedRegistration = await fetch(base + "/register", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ client_name: "attacker", redirect_uris: ["https://attacker.example/callback"] }),
  });
  assert.equal(rejectedRegistration.status, 400);
  assert.equal((await bodyJson(rejectedRegistration)).error, "invalid_redirect_uri");

  const unauth = await fetch(base + "/mcp", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list", params: {} }),
  });
  assert.equal(unauth.status, 401);
  assert.match(unauth.headers.get("www-authenticate") || "", /resource_metadata=.*oauth-protected-resource\/mcp/);

  const badAudience = new URL(base + "/authorize");
  for (const [k, v] of Object.entries({
    response_type: "code", client_id: clientId, redirect_uri: redirectUri,
    state: "state-bad", code_challenge: challenge, code_challenge_method: "S256",
    resource: "https://attacker.example/mcp",
  })) badAudience.searchParams.set(k, v);
  const bad = await fetch(badAudience, { redirect: "manual" });
  assert.equal(bad.status, 302);
  assert.match(bad.headers.get("location") || "", /error=invalid_target/);

  const authUrl = new URL(base + "/authorize");
  for (const [k, v] of Object.entries({
    response_type: "code", client_id: clientId, redirect_uri: redirectUri,
    state: "state-ok", code_challenge: challenge, code_challenge_method: "S256",
    resource: base + "/mcp",
  })) authUrl.searchParams.set(k, v);
  const consent = await fetch(authUrl);
  assert.equal(consent.status, 200);
  const consentHtml = await consent.text();
  const rid = /name="rid" value="([a-f0-9]+)"/.exec(consentHtml)?.[1];
  assert.ok(rid, "consent page must carry a request id");

  const approved = await fetch(base + "/authorize", {
    method: "POST",
    redirect: "manual",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: form({ rid, bearer: token }),
  });
  assert.equal(approved.status, 302);
  const callback = new URL(approved.headers.get("location"));
  const code = callback.searchParams.get("code");
  assert.ok(code);
  assert.equal(callback.searchParams.get("state"), "state-ok");
  assert.equal(callback.searchParams.get("iss"), base);

  const tokensResponse = await fetch(base + "/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: form({
      grant_type: "authorization_code", client_id: clientId, code,
      redirect_uri: redirectUri, code_verifier: verifier, resource: base + "/mcp",
    }),
  });
  assert.equal(tokensResponse.status, 200);
  const tokens = await bodyJson(tokensResponse);
  assert.ok(tokens.access_token);
  assert.ok(tokens.refresh_token);

  await stopGateway(gateway);
  gateway = startGateway(gatewayPort, upstreamPort);
  await waitForGateway(gateway, base);

  const list = await fetch(base + "/mcp", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "authorization": "Bearer " + tokens.access_token,
    },
    body: JSON.stringify({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} }),
  });
  assert.equal(list.status, 200);
  const listBody = await bodyJson(list);
  const names = listBody.result.tools.map((tool) => tool.name);
  assert.ok(names.includes("shell_exec"));
  for (const tool of listBody.result.tools) {
    assert.deepEqual(tool.securitySchemes, [{ type: "oauth2", scopes: ["mcp"] }]);
    assert.deepEqual(tool._meta.securitySchemes, [{ type: "oauth2", scopes: ["mcp"] }]);
  }

  const call = await fetch(base + "/mcp", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "authorization": "Bearer " + tokens.access_token,
    },
    body: JSON.stringify({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "shell_exec", arguments: { command: "echo test" } } }),
  });
  assert.equal(call.status, 200);
  assert.equal((await bodyJson(call)).result.content[0].text, "ok:shell_exec");

  const refreshBadAudience = await fetch(base + "/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: form({
      grant_type: "refresh_token", client_id: clientId,
      refresh_token: tokens.refresh_token, resource: "https://attacker.example/mcp",
    }),
  });
  assert.equal(refreshBadAudience.status, 400);
  assert.equal((await bodyJson(refreshBadAudience)).error, "invalid_target");

  const refresh = await fetch(base + "/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: form({
      grant_type: "refresh_token", client_id: clientId,
      refresh_token: tokens.refresh_token, resource: base + "/mcp",
    }),
  });
  assert.equal(refresh.status, 200);
  assert.ok((await bodyJson(refresh)).access_token);

  console.log("oauth-integration: ok");
} finally {
  await stopGateway(gateway);
  await new Promise((r) => upstream.close(r));
  fs.rmSync(temp, { recursive: true, force: true });
}
