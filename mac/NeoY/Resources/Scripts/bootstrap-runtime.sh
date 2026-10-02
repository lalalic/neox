#!/bin/zsh
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.volta/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
SCRIPT_DIR="${0:A:h}"
DATA="$HOME/Library/Application Support/NeoY"
RUNTIME_ROOT="$DATA/runtime"
RUNTIME_SOURCE="$SCRIPT_DIR/neoy-runtime"
RUNTIME_DIR="$RUNTIME_ROOT/neoy-runtime"
SKILLS_ROOT="$HOME/.agents/skills"
EVENTS_DIR="$SKILLS_ROOT/events-bus"
BROWSER_WORKSPACE_DIR="$SKILLS_ROOT/browser-workspace"
CONTROL_PLANE="$DATA/control-plane.json"

log() { print -r -- "[NeoY bootstrap] $*"; }
fail() { print -u2 -r -- "[NeoY bootstrap] $*"; exit 1; }

refresh_path() {
  export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.volta/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
  rehash 2>/dev/null || true
}

node_ready() {
  command -v node >/dev/null 2>&1 || return 1
  command -v npm >/dev/null 2>&1 || return 1
  command -v npx >/dev/null 2>&1 || return 1
  local major
  major="$(node -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || print 0)"
  [[ "$major" -ge 18 ]]
}

ensure_node_toolchain() {
  refresh_path
  if node_ready; then
    log "Node toolchain ready: node $(node --version), npm $(npm --version), npx $(npx --version)"
    return
  fi

  if command -v brew >/dev/null 2>&1; then
    log "Installing Node.js with Homebrew"
    if brew list node >/dev/null 2>&1; then
      brew upgrade node || true
    else
      brew install node
    fi
  else
    command -v curl >/dev/null 2>&1 || fail "curl is required to bootstrap Node.js"
    log "Homebrew not found; installing user-local Node.js with Volta"
    export VOLTA_HOME="$HOME/.volta"
    mkdir -p "$VOLTA_HOME"
    curl --fail --silent --show-error https://get.volta.sh | /bin/bash -s -- --skip-setup
    "$VOLTA_HOME/bin/volta" install node@22
  fi

  refresh_path
  node_ready || fail "Node.js 18+, npm, and npx are required but could not be prepared"
  log "Node toolchain ready: node $(node --version), npm $(npm --version), npx $(npx --version)"
}

install_skill_if_missing() {
  local repo="$1"
  local skill="$2"
  local sentinel="$3"
  if [[ -e "$sentinel" ]]; then
    log "Required skill ready: $skill"
    return
  fi
  log "Installing required skill: $skill"
  npx --yes skills add "$repo" --skill "$skill" --global --agent codex --yes --copy
}

install_required_skills() {
  mkdir -p "$SKILLS_ROOT"
  install_skill_if_missing https://github.com/lalalic/neo events-bus "$EVENTS_DIR/mcp/server.mjs"
  install_skill_if_missing https://github.com/lalalic/browser-workspace browser-workspace "$BROWSER_WORKSPACE_DIR/bin/browser-workspace"

  [[ -f "$EVENTS_DIR/mcp/server.mjs" ]] || fail "events-bus installed without mcp/server.mjs"
  [[ -x "$BROWSER_WORKSPACE_DIR/bin/browser-workspace" ]] || fail "browser-workspace installed without executable CLI"

  if [[ -f "$EVENTS_DIR/package-lock.json" ]]; then
    (cd "$EVENTS_DIR" && npm ci --omit=dev)
  elif [[ -f "$EVENTS_DIR/package.json" ]]; then
    (cd "$EVENTS_DIR" && npm install --omit=dev)
  fi
}

install_neoy_runtime() {
  [[ -f "$RUNTIME_SOURCE/package.json" ]] || fail "NeoY runtime source is missing: $RUNTIME_SOURCE"
  [[ -f "$RUNTIME_SOURCE/package-lock.json" ]] || fail "NeoY runtime lockfile is missing: $RUNTIME_SOURCE/package-lock.json"

  if [[ -f "$RUNTIME_DIR/package-lock.json" && -f "$RUNTIME_DIR/node_modules/mac-developer-bridge/bridge.mjs" ]] && \
     cmp -s "$RUNTIME_SOURCE/package-lock.json" "$RUNTIME_DIR/package-lock.json"; then
    log "NeoY Node runtime ready"
    return
  fi

  local stage="$RUNTIME_ROOT/neoy-runtime.new"
  log "Installing NeoY Node runtime and dependencies"
  mkdir -p "$RUNTIME_ROOT"
  rm -rf "$stage"
  /usr/bin/ditto "$RUNTIME_SOURCE" "$stage"
  rm -rf "$stage/node_modules"
  (cd "$stage" && npm ci --omit=dev)
  [[ -f "$stage/node_modules/mac-developer-bridge/bridge.mjs" ]] || fail "NeoY runtime dependency mac-developer-bridge is missing"
  rm -rf "$RUNTIME_DIR"
  mv "$stage" "$RUNTIME_DIR"
}

configure_events_provider() {
  local node_bin="$(command -v node)"
  mkdir -p "$DATA"
  NODE_BIN="$node_bin" EVENTS_SERVER="$EVENTS_DIR/mcp/server.mjs" CONTROL_PLANE="$CONTROL_PLANE" python3 <<'PYCONFIG'
import json, os
from pathlib import Path
from urllib.parse import quote

path = Path(os.environ["CONTROL_PLANE"])
node = os.environ["NODE_BIN"]
server = os.environ["EVENTS_SERVER"]
url = f"stdio://{quote(node, safe='/')}?arg={quote(server, safe='')}"
try:
    doc = json.loads(path.read_text()) if path.exists() else {}
except Exception:
    doc = {}
if not isinstance(doc, dict):
    doc = {}
doc["schemaVersion"] = 3
config = doc.setdefault("configuration", {})
config.setdefault("diagnostics", {"isEnabled": False, "level": "info", "retentionDays": 7})
config.setdefault("events", {"blocked": True, "failure": True, "completed": True})
config.setdefault("capabilities", {"disabled": []})
servers = config.setdefault("mcpServers", [])
servers = [s for s in servers if isinstance(s, dict) and s.get("name") != "events"]
servers.append({"name": "events", "url": url, "isEnabled": True})
config["mcpServers"] = servers
path.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n")
print(f"Configured NeoY MCP provider events -> {url}")
PYCONFIG
}

ensure_node_toolchain
install_required_skills
install_neoy_runtime
configure_events_provider

log "Runtime ready"
log "  events-bus: $EVENTS_DIR"
log "  browser-workspace: $BROWSER_WORKSPACE_DIR"
log "  neoy-runtime: $RUNTIME_DIR"
