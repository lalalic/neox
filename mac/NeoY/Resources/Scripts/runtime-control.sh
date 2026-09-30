#!/bin/zsh
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
PM2="${PM2_BIN:-$(command -v pm2 2>/dev/null || true)}"
CLOUDFLARED="${CLOUDFLARED_BIN:-$(command -v cloudflared 2>/dev/null || true)}"
DATA="$HOME/Library/Application Support/NeoY"
SETTINGS="$DATA/deployment.json"
LOGDIR="$HOME/Library/Logs/NeoY"
PUBLIC="$DATA/public-url"
TUNNEL_LOG="$LOGDIR/tunnel.log"
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

PORT="$(read_json mcpPort 9224)"
MODE="$(read_json tunnelMode off)"
TUNNEL_NAME="$(read_json tunnelName neoy)"
HOSTNAME="$(read_json publicHostname '')"

need_pm2() { [[ -n "$PM2" ]] || { print -u2 "pm2 not found"; exit 69; }; }
need_cloudflared() { [[ -n "$CLOUDFLARED" ]] || { print -u2 "cloudflared not found"; exit 69; }; }

write_pm2_config() {
  cat > "$DATA/neoy-pm2.config.cjs" <<EOF
module.exports = { apps: [
  {
    name: "neoy",
    script: "/Applications/NeoY.app/Contents/MacOS/NeoY",
    interpreter: "none",
    autorestart: true,
    restart_delay: 1000,
    out_file: "$LOGDIR/neoy.out.log",
    error_file: "$LOGDIR/neoy.err.log"
  }
] };
EOF
}

pm2_setup() {
  need_pm2
  [[ -x /Applications/NeoY.app/Contents/MacOS/NeoY ]] || { print -u2 "Install /Applications/NeoY.app first"; exit 66; }
  write_pm2_config
  launchctl bootout "gui/$UID/com.neox.neoy.keepalive" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/LaunchAgents/com.neox.neoy.keepalive.plist"
  "$PM2" delete neoy >/dev/null 2>&1 || true
  "$PM2" start "$DATA/neoy-pm2.config.cjs" --only neoy --update-env >/dev/null
  "$PM2" save --force >/dev/null
  print "NeoY is supervised by PM2"
}

tunnel_stop() {
  [[ -n "$PM2" ]] && "$PM2" delete neoy-tunnel >/dev/null 2>&1 || true
  rm -f "$PUBLIC"
}

tunnel_start() {
  need_pm2
  need_cloudflared
  tunnel_stop
  [[ "$MODE" != "off" ]] || { print "Tunnel is off"; return 0; }
  : > "$TUNNEL_LOG"

  if [[ "$MODE" == "quick" ]]; then
    "$PM2" start "$CLOUDFLARED" --name neoy-tunnel --interpreter none --log "$TUNNEL_LOG" --       tunnel --no-autoupdate --url "http://127.0.0.1:$PORT" >/dev/null
  else
    [[ -n "$TUNNEL_NAME" && -n "$HOSTNAME" ]] || {
      print -u2 "named tunnel requires tunnelName and publicHostname"; return 64
    }
    local tid
    tid="$("$CLOUDFLARED" tunnel list --output json | /usr/bin/python3 -c 'import json,sys; n=sys.argv[1]; x=json.load(sys.stdin); print(next((i["id"] for i in x if i["name"]==n),""))' "$TUNNEL_NAME")"
    [[ -n "$tid" ]] || { print -u2 "Cloudflare tunnel '$TUNNEL_NAME' does not exist"; return 66; }
    local creds="$HOME/.cloudflared/$tid.json"
    cat > "$DATA/cloudflared.yml" <<EOF
tunnel: $tid
credentials-file: $creds
ingress:
  - hostname: $HOSTNAME
    service: http://127.0.0.1:$PORT
  - service: http_status:404
EOF
    "$PM2" start "$CLOUDFLARED" --name neoy-tunnel --interpreter none --log "$TUNNEL_LOG" --       tunnel --config "$DATA/cloudflared.yml" run "$tid" >/dev/null
    print -r -- "https://$HOSTNAME" > "$PUBLIC"
  fi

  "$PM2" save --force >/dev/null
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
  [[ -n "$TUNNEL_NAME" && -n "$HOSTNAME" ]] || {
    print -u2 "named tunnel requires tunnelName and publicHostname"; exit 64
  }
  if ! "$CLOUDFLARED" tunnel list --output json | /usr/bin/python3 -c 'import json,sys; n=sys.argv[1]; x=json.load(sys.stdin); raise SystemExit(0 if any(i["name"]==n for i in x) else 1)' "$TUNNEL_NAME"; then
    "$CLOUDFLARED" tunnel create "$TUNNEL_NAME"
  fi
  "$CLOUDFLARED" tunnel route dns "$TUNNEL_NAME" "$HOSTNAME"
  print "Named tunnel ready: https://$HOSTNAME/mcp"
}

case "$ACTION" in
  pm2-setup) pm2_setup ;;
  tunnel-start) tunnel_start ;;
  tunnel-stop) tunnel_stop; print "Tunnel stopped" ;;
  tunnel-restart) tunnel_start ;;
  named-create) named_create ;;
  status)
    print "port=$PORT mode=$MODE"
    [[ -f "$PUBLIC" ]] && print "public=$(cat "$PUBLIC")/mcp"
    if [[ -n "$PM2" ]]; then
      "$PM2" jlist | jq -r '.[] | select(.name=="neoy" or .name=="neoy-tunnel") | "\(.name)=\(.pm2_env.status)"'
    fi
    ;;
  *) print -u2 "usage: runtime-control.sh pm2-setup|tunnel-start|tunnel-stop|tunnel-restart|named-create|status"; exit 64 ;;
esac
