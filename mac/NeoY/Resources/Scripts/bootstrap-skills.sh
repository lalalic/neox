#!/bin/zsh
set -euo pipefail

if ! command -v npx >/dev/null 2>&1; then
  print -u2 "NeoY requires npx to install required skill: events-bus."
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  print -u2 "NeoY requires Node.js to run the events-bus MCP provider."
  exit 1
fi

SKILLS_ROOT="$HOME/.agents/skills"
EVENTS_DIR="$SKILLS_ROOT/events-bus"

echo "Installing NeoY required skill: events-bus"
npx --yes skills add https://github.com/lalalic/neo \
  --skill events-bus --global --agent codex --yes --copy

if [[ ! -f "$EVENTS_DIR/mcp/server.mjs" ]]; then
  print -u2 "events-bus skill installed without mcp/server.mjs: $EVENTS_DIR"
  exit 1
fi
if [[ -f "$EVENTS_DIR/package-lock.json" ]]; then
  (cd "$EVENTS_DIR" && npm ci --omit=dev)
elif [[ -f "$EVENTS_DIR/package.json" ]]; then
  (cd "$EVENTS_DIR" && npm install --omit=dev)
fi

NODE_BIN="$(command -v node)"
CONTROL_PLANE="$HOME/Library/Application Support/NeoY/control-plane.json"
mkdir -p "${CONTROL_PLANE:h}"

NODE_BIN="$NODE_BIN" EVENTS_SERVER="$EVENTS_DIR/mcp/server.mjs" CONTROL_PLANE="$CONTROL_PLANE" python3 <<'PYCONFIG'
import json, os
from pathlib import Path
from urllib.parse import quote

path = Path(os.environ["CONTROL_PLANE"])
node = os.environ["NODE_BIN"]
server = os.environ["EVENTS_SERVER"]
url = f"stdio://{quote(node, safe='/')}?arg={quote(server, safe='')}"

if path.exists():
    try:
        doc = json.loads(path.read_text())
    except Exception:
        doc = {}
else:
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

echo "NeoY required skills ready:"
echo "  events-bus: $EVENTS_DIR"
