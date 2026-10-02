#!/bin/zsh
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
NPX="${NPX_BIN:-$(command -v npx 2>/dev/null || true)}"
NODE="${NODE_BIN:-$(command -v node 2>/dev/null || true)}"
CLOUDFLARED="${CLOUDFLARED_BIN:-$(command -v cloudflared 2>/dev/null || true)}"
SCRIPT_DIR="${0:A:h}"
NODE_RUNTIME_DIR="$SCRIPT_DIR/neoy-runtime"
DATA="$HOME/Library/Application Support/NeoY"
SETTINGS="$DATA/deployment.json"
LOGDIR="$HOME/Library/Logs/NeoY"
PUBLIC="$DATA/public-url"
TUNNEL_LOG="$LOGDIR/tunnel.log"
GATEWAY_LOG="$LOGDIR/mcp-gateway.log"
GATEWAY_PORT="${NEOY_GATEWAY_PORT:-6768}"
TOKEN_FILE="$DATA/core-token"
CLIENT_ID_FILE="$DATA/oauth-client-id"
ACTION="${1:-status}"

mkdir -p "$DATA" "$LOGDIR"
chmod 700 "$DATA" "$LOGDIR" 2>/dev/null || true

read_json() {
  /usr/bin/python3 - "$SETTINGS" "$1" "$2" <<'PY'
import json,sys
p,k,d=sys.argv[1:]
try:
    with open(p) as f: obj=json.load(f)
    v=obj.get(k,d)
except Exception:
    v=d
print(v)
PY
}

PORT="$(read_json mcpPort 6767)"
MODE="$(read_json tunnelMode off)"
TUNNEL_NAME="$(read_json tunnelName '')"
HOSTNAME="$(read_json publicHostname '')"

need_npx() { [[ -n "$NPX" ]] || { print -u2 "npx not found"; exit 69; }; }
pm2() {
  need_npx
  "$NPX" --yes pm2 "$@"
}
need_cloudflared() { [[ -n "$CLOUDFLARED" ]] || { print -u2 "cloudflared not found"; exit 69; }; }
need_node() { [[ -n "$NODE" ]] || { print -u2 "node not found"; exit 69; }; }

ensure_client_id() {
  if [[ ! -s "$CLIENT_ID_FILE" ]]; then
    /usr/bin/python3 - "$CLIENT_ID_FILE" <<'PY2'
import secrets,sys,os
p=sys.argv[1]
with open(p,'w') as f: f.write("neo-" + secrets.token_hex(16) + "\n")
os.chmod(p,0o600)
PY2
  fi
}

gateway_stop() {
  [[ -n "$NPX" ]] && pm2 delete neoy-mcp-gateway >/dev/null 2>&1 || true
}

gateway_start() {
  need_npx
  need_node
  [[ -s "$TOKEN_FILE" ]] || { print -u2 "NeoY core token is missing"; return 69; }
  [[ -f "$NODE_RUNTIME_DIR/src/mcp-gateway.mjs" ]] || { print -u2 "NeoY MCP gateway script is missing"; return 69; }
  [[ -f "$NODE_RUNTIME_DIR/src/stdio-proxy.mjs" ]] || { print -u2 "NeoY MCP proxy script is missing"; return 69; }
  ensure_client_id
  gateway_stop
  : > "$GATEWAY_LOG"
  export NEOY_HTTP_PORT="$GATEWAY_PORT"
  export NEOY_HTTP_TOKEN_FILE="$TOKEN_FILE"
  export NEOY_TOKEN_FILE="$TOKEN_FILE"
  export NEOY_DATA_DIR="$DATA"
  export NEOY_ENTRY="$NODE_RUNTIME_DIR/src/stdio-proxy.mjs"
  export NEOY_UPSTREAM="http://127.0.0.1:$PORT/mcp"
  export NEOY_OAUTH_CLIENT_ID="$(cat "$CLIENT_ID_FILE")"
  if [[ -n "$HOSTNAME" ]]; then
    export NEOY_PUBLIC_URL="https://$HOSTNAME"
  else
    unset NEOY_PUBLIC_URL 2>/dev/null || true
  fi
  pm2 start "$NODE_RUNTIME_DIR/src/mcp-gateway.mjs" --name neoy-mcp-gateway --interpreter "$NODE" --log "$GATEWAY_LOG" --update-env >/dev/null
}

tunnel_stop() {
  [[ -n "$NPX" ]] && pm2 delete neoy-tunnel >/dev/null 2>&1 || true
  gateway_stop
  rm -f "$PUBLIC"
}

tunnel_start() {
  need_npx
  need_cloudflared
  tunnel_stop
  [[ "$MODE" != "off" ]] || { print "Tunnel is off"; return 0; }
  : > "$TUNNEL_LOG"
  gateway_start

  if [[ "$MODE" == "quick" ]]; then
    pm2 start "$CLOUDFLARED" --name neoy-tunnel --interpreter none --log "$TUNNEL_LOG" --       tunnel --no-autoupdate --url "http://127.0.0.1:$GATEWAY_PORT" >/dev/null
  else
    [[ -n "$HOSTNAME" ]] || {
      print -u2 "named tunnel requires a public hostname"; return 64
    }
    if [[ -z "$TUNNEL_NAME" ]]; then
      TUNNEL_NAME="$(/usr/bin/python3 - "$HOSTNAME" <<'PY2'
import hashlib, re, sys
host=sys.argv[1].lower()
slug=re.sub(r'[^a-z0-9]+', '-', host).strip('-')[:32]
hash=hashlib.sha256(host.encode()).hexdigest()[:8]
print(f"neoy-{slug}-{hash}")
PY2
)"
    fi
    local tid
    tid="$("$CLOUDFLARED" tunnel list --output json | /usr/bin/python3 -c 'import json,sys; n=sys.argv[1]; x=json.load(sys.stdin); print(next((i["id"] for i in x if i["name"]==n),""))' "$TUNNEL_NAME")"
    [[ -n "$tid" ]] || { print -u2 "Cloudflare tunnel '$TUNNEL_NAME' does not exist"; return 66; }
    local creds="$HOME/.cloudflared/$tid.json"
    cat > "$DATA/cloudflared.yml" <<EOF
tunnel: $tid
credentials-file: $creds
ingress:
  - hostname: $HOSTNAME
    service: http://127.0.0.1:$GATEWAY_PORT
  - service: http_status:404
EOF
    pm2 start "$CLOUDFLARED" --name neoy-tunnel --interpreter none --log "$TUNNEL_LOG" --       tunnel --config "$DATA/cloudflared.yml" run "$tid" >/dev/null
    print -r -- "https://$HOSTNAME" > "$PUBLIC"
  fi

  pm2 save --force >/dev/null
  if [[ "$MODE" == "quick" ]]; then
    local url=""
    for _ in {1..120}; do
      url="$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" | tail -1 || true)"
      [[ -n "$url" ]] && break
      sleep 0.25
    done
    [[ -n "$url" ]] || { print -u2 "quick tunnel started but URL not discovered"; return 70; }
    print -r -- "$url" > "$PUBLIC"
  fi
  chmod 600 "$PUBLIC" 2>/dev/null || true
  print "Public MCP: $(cat "$PUBLIC")/mcp"
}

named_create() {
  need_cloudflared
  [[ -n "$HOSTNAME" ]] || {
    print -u2 "named tunnel requires a public hostname"; exit 64
  }
  if [[ -z "$TUNNEL_NAME" ]]; then
    TUNNEL_NAME="$(/usr/bin/python3 - "$HOSTNAME" <<'PY2'
import hashlib, re, sys
host=sys.argv[1].lower()
slug=re.sub(r'[^a-z0-9]+', '-', host).strip('-')[:32]
hash=hashlib.sha256(host.encode()).hexdigest()[:8]
print(f"neoy-{slug}-{hash}")
PY2
)"
  fi
  if ! "$CLOUDFLARED" tunnel list --output json | /usr/bin/python3 -c 'import json,sys; n=sys.argv[1]; x=json.load(sys.stdin); raise SystemExit(0 if any(i["name"]==n for i in x) else 1)' "$TUNNEL_NAME"; then
    "$CLOUDFLARED" tunnel create "$TUNNEL_NAME"
  fi
  "$CLOUDFLARED" tunnel route dns "$TUNNEL_NAME" "$HOSTNAME"
  print "Named tunnel ready: https://$HOSTNAME/mcp"
}

case "$ACTION" in
  tunnel-start) tunnel_start ;;
  tunnel-stop) tunnel_stop; print "Tunnel stopped" ;;
  tunnel-restart) tunnel_start ;;
  named-create) named_create ;;
  named-apply) named_create; tunnel_start ;;
  status)
    print "port=$PORT gateway_port=$GATEWAY_PORT mode=$MODE"
    [[ -f "$PUBLIC" ]] && print "public=$(cat "$PUBLIC")/mcp"
    [[ -f "$CLIENT_ID_FILE" ]] && print "oauth_client_id=$(cat "$CLIENT_ID_FILE")"
    if [[ -n "$NPX" ]]; then
      pm2 jlist | jq -r '.[] | select(.name=="neoy-tunnel" or .name=="neoy-mcp-gateway") | "\(.name)=\(.pm2_env.status)"'
    fi
    ;;
  *) print -u2 "usage: runtime-control.sh tunnel-start|tunnel-stop|tunnel-restart|named-create|named-apply|status"; exit 64 ;;
esac
