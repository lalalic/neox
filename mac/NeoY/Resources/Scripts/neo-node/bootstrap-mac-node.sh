#!/bin/zsh
set -euo pipefail

CONFIG_FILE="${NEO_NODE_CONFIG:-$HOME/.config/neo-node/node.env}"
[[ -f "$CONFIG_FILE" ]] || { print -u2 -- "missing config: $CONFIG_FILE"; exit 64; }
set -a
source "$CONFIG_FILE"
set +a

: "${NODE_NAME:?NODE_NAME is required}"
: "${HUB_SSH_TARGET:?HUB_SSH_TARGET is required}"
: "${HUB_MCP_PORT:?HUB_MCP_PORT is required}"

NODE_MODE="${NODE_MODE:-session}"
LOCAL_MCP_PORT="${LOCAL_MCP_PORT:-8789}"
NODE_ROOT="${NODE_ROOT:-$HOME/.local/share/neo-node}"
PYTHON_BIN="${PYTHON_BIN:-/usr/bin/python3}"
SSH_BIN="${SSH_BIN:-/usr/bin/ssh}"
SERVER="$NODE_ROOT/mac-node-server.py"
LOG_DIR="$NODE_ROOT/logs"
PID_DIR="$NODE_ROOT/run"
KEY_FILE="${NODE_SSH_KEY:-$HOME/.config/neo-node/id_ed25519}"
HUB_SSH_PORT="${HUB_SSH_PORT:-22}"
LAUNCH_LABEL="com.neo.mac-node.$NODE_NAME"
LAUNCH_PLIST="$HOME/Library/LaunchAgents/$LAUNCH_LABEL.plist"
CLI_PATH="$HOME/.local/bin/neo-node"
SUPERVISOR_PID_FILE="$PID_DIR/supervisor.pid"
SERVER_PID_FILE="$PID_DIR/server.pid"
TUNNEL_PID_FILE="$PID_DIR/tunnel.pid"
RECONNECT_MAX_SECONDS="${NEO_NODE_RECONNECT_MAX_SECONDS:-30}"

case "$NODE_MODE" in
  session|persistent) ;;
  *) print -u2 -- "invalid NODE_MODE=$NODE_MODE (expected session|persistent)"; exit 64 ;;
esac

mkdir -p "$LOG_DIR" "$PID_DIR"

read_pid() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  local pid
  pid="$(cat "$file" 2>/dev/null || true)"
  [[ "$pid" == <-> ]] || return 1
  print -- "$pid"
}

pid_alive() {
  local pid
  pid="$(read_pid "$1")" || return 1
  kill -0 "$pid" 2>/dev/null
}

pid_status() {
  local label="$1" file="$2" pid
  if pid="$(read_pid "$file")"; then
    if kill -0 "$pid" 2>/dev/null; then
      print -- "$label pid: $pid (alive)"
    else
      print -- "$label pid: $pid (stale)"
    fi
  else
    print -- "$label pid: missing"
  fi
}

local_mcp_healthy() {
  curl -fsS "http://127.0.0.1:$LOCAL_MCP_PORT/healthz" >/dev/null 2>&1
}

epoch_seconds() {
  date +%s
}

discover_server_pid() {
  local pid command
  command -v pgrep >/dev/null 2>&1 || return 1
  for pid in $(pgrep -f "$SERVER" 2>/dev/null || true); do
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    [[ "$command" == *"$SERVER"* ]] || continue
    print -- "$pid"
    return 0
  done
  return 1
}

reconcile_server_pid() {
  local pid
  if pid_alive "$SERVER_PID_FILE"; then
    return 0
  fi
  if local_mcp_healthy && pid="$(discover_server_pid)"; then
    print -- "$pid" > "$SERVER_PID_FILE"
    return 0
  fi
  rm -f "$SERVER_PID_FILE"
  return 1
}

install_cli() {
  mkdir -p "$HOME/.local/bin"
  cat > "$CLI_PATH" <<EOF
#!/bin/zsh
exec /bin/zsh "$NODE_ROOT/bootstrap-mac-node.sh" "\$@"
EOF
  chmod 755 "$CLI_PATH"
}

start_server() {
  if reconcile_server_pid; then
    return 0
  fi
  MAC_NODE_NAME="$NODE_NAME" MAC_NODE_PORT="$LOCAL_MCP_PORT" MAC_NODE_HOST=127.0.0.1 \
    "$PYTHON_BIN" "$SERVER" >>"$LOG_DIR/server.log" 2>&1 &
  echo $! > "$SERVER_PID_FILE"
}

start_tunnel() {
  if pid_alive "$TUNNEL_PID_FILE"; then
    return 0
  fi
  rm -f "$TUNNEL_PID_FILE"
  local ssh_args=(
    -N
    -o BatchMode=yes
    -o ExitOnForwardFailure=yes
    -o ServerAliveInterval=20
    -o ServerAliveCountMax=3
    -o StrictHostKeyChecking=accept-new
    -p "$HUB_SSH_PORT"
  )
  if [[ -n "$KEY_FILE" && -f "$KEY_FILE" ]]; then
    ssh_args+=(-i "$KEY_FILE")
  fi
  ssh_args+=(
    -R "127.0.0.1:$HUB_MCP_PORT:127.0.0.1:$LOCAL_MCP_PORT"
    "$HUB_SSH_TARGET"
  )
  "$SSH_BIN" "${ssh_args[@]}" >>"$LOG_DIR/tunnel.log" 2>&1 &
  echo $! > "$TUNNEL_PID_FILE"
}

stop_all() {
  local supervisor_pid="" tunnel_pid="" server_pid="" discovered_server=""
  supervisor_pid="$(read_pid "$SUPERVISOR_PID_FILE" 2>/dev/null || true)"
  tunnel_pid="$(read_pid "$TUNNEL_PID_FILE" 2>/dev/null || true)"
  server_pid="$(read_pid "$SERVER_PID_FILE" 2>/dev/null || true)"

  [[ -n "$supervisor_pid" ]] && kill "$supervisor_pid" 2>/dev/null || true
  [[ -n "$tunnel_pid" ]] && kill "$tunnel_pid" 2>/dev/null || true
  [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null || true

  if discovered_server="$(discover_server_pid 2>/dev/null)" && [[ "$discovered_server" != "$$" ]]; then
    kill "$discovered_server" 2>/dev/null || true
  fi

  rm -f "$SUPERVISOR_PID_FILE" "$TUNNEL_PID_FILE" "$SERVER_PID_FILE"
}

run_foreground() {
  local server_pid="" tunnel_pid="" reconnect_delay=1 tunnel_started_at=0 now=0
  local existing_supervisor=""

  if existing_supervisor="$(read_pid "$SUPERVISOR_PID_FILE" 2>/dev/null)" \
    && [[ "$existing_supervisor" != "$$" ]] \
    && kill -0 "$existing_supervisor" 2>/dev/null; then
    print -u2 -- "neo-node supervisor already running: $existing_supervisor"
    return 0
  fi

  print -- "$$" > "$SUPERVISOR_PID_FILE"
  trap '
    [[ -n "$tunnel_pid" ]] && kill "$tunnel_pid" 2>/dev/null || true
    [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null || true
    rm -f "$SUPERVISOR_PID_FILE" "$TUNNEL_PID_FILE" "$SERVER_PID_FILE"
  ' EXIT INT TERM

  while true; do
    if ! reconcile_server_pid; then
      start_server
    fi
    server_pid="$(read_pid "$SERVER_PID_FILE")"

    for _ in {1..20}; do
      local_mcp_healthy && break
      sleep 0.25
    done
    if ! local_mcp_healthy; then
      print -u2 -- "local MCP failed to become healthy; retrying"
      kill "$server_pid" 2>/dev/null || true
      rm -f "$SERVER_PID_FILE"
      server_pid=""
      sleep "$reconnect_delay"
      (( reconnect_delay = reconnect_delay < RECONNECT_MAX_SECONDS ? reconnect_delay * 2 : RECONNECT_MAX_SECONDS ))
      continue
    fi

    if ! pid_alive "$TUNNEL_PID_FILE"; then
      start_tunnel
      tunnel_pid="$(read_pid "$TUNNEL_PID_FILE")"
      tunnel_started_at="$(epoch_seconds)"
    else
      tunnel_pid="$(read_pid "$TUNNEL_PID_FILE")"
      if (( tunnel_started_at == 0 )); then
        tunnel_started_at="$(epoch_seconds)"
      fi
    fi

    sleep 5

    if ! kill -0 "$tunnel_pid" 2>/dev/null; then
      rm -f "$TUNNEL_PID_FILE"
      now="$(epoch_seconds)"
      if (( now - tunnel_started_at >= 30 )); then
        reconnect_delay=1
      fi
      print -u2 -- "reverse SSH tunnel exited; reconnecting in ${reconnect_delay}s"
      sleep "$reconnect_delay"
      (( reconnect_delay = reconnect_delay < RECONNECT_MAX_SECONDS ? reconnect_delay * 2 : RECONNECT_MAX_SECONDS ))
      tunnel_pid=""
      tunnel_started_at=0
      continue
    fi

    now="$(epoch_seconds)"
    if (( now - tunnel_started_at >= 30 )); then
      reconnect_delay=1
    fi
  done
}

start_supervisor() {
  if pid_alive "$SUPERVISOR_PID_FILE"; then
    return 0
  fi
  rm -f "$SUPERVISOR_PID_FILE"
  nohup /bin/zsh "$NODE_ROOT/bootstrap-mac-node.sh" run >>"$LOG_DIR/supervisor.log" 2>&1 &
  echo $! > "$SUPERVISOR_PID_FILE"

  for _ in {1..40}; do
    if local_mcp_healthy && pid_alive "$TUNNEL_PID_FILE"; then
      return 0
    fi
    sleep 0.25
  done
  local_mcp_healthy && pid_alive "$TUNNEL_PID_FILE"
}

install_launchd() {
  [[ "$NODE_MODE" == "persistent" ]] || {
    print -- "NODE_MODE=$NODE_MODE: LaunchD installation skipped"
    return 0
  }
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$LAUNCH_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LAUNCH_LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/zsh</string>
    <string>$NODE_ROOT/bootstrap-mac-node.sh</string>
    <string>run</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>StandardOutPath</key><string>$LOG_DIR/launchd.out.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/launchd.err.log</string>
</dict></plist>
PLIST
  launchctl bootout "gui/$(id -u)/$LAUNCH_LABEL" 2>/dev/null || true
  launchctl unload "$LAUNCH_PLIST" 2>/dev/null || true
  if ! launchctl bootstrap "gui/$(id -u)" "$LAUNCH_PLIST" 2>/dev/null; then
    launchctl load -w "$LAUNCH_PLIST"
  fi
}

uninstall_persistence() {
  launchctl bootout "gui/$(id -u)/$LAUNCH_LABEL" 2>/dev/null || true
  launchctl unload "$LAUNCH_PLIST" 2>/dev/null || true
  rm -f "$LAUNCH_PLIST"
}

status() {
  print -- "node: $NODE_NAME"
  print -- "mode: $NODE_MODE"
  print -- "root: $NODE_ROOT"
  if local_mcp_healthy; then
    print -- "local MCP: healthy"
  else
    print -- "local MCP: unavailable"
  fi
  pid_status "supervisor" "$SUPERVISOR_PID_FILE"
  pid_status "server" "$SERVER_PID_FILE"
  pid_status "tunnel" "$TUNNEL_PID_FILE"
  if [[ -f "$LAUNCH_PLIST" ]]; then
    print -- "launchd plist: present"
  else
    print -- "launchd plist: absent"
  fi
}

doctor() {
  local failed=0
  print -- "neo-node doctor"
  print -- "node=$NODE_NAME mode=$NODE_MODE"

  for f in "$CONFIG_FILE" "$SERVER"; do
    if [[ -e "$f" ]]; then print -- "ok file $f"; else print -- "missing $f"; failed=1; fi
  done
  if [[ -n "$KEY_FILE" ]]; then
    if [[ -e "$KEY_FILE" ]]; then print -- "ok file $KEY_FILE"; else print -- "info SSH identity not found; default SSH identities will be used"; fi
  fi
  for b in "$PYTHON_BIN" "$SSH_BIN" /usr/bin/curl; do
    if [[ -x "$b" ]]; then print -- "ok executable $b"; else print -- "missing executable $b"; failed=1; fi
  done

  if [[ "$NODE_MODE" == "session" && -f "$LAUNCH_PLIST" ]]; then
    print -- "warning: session node has legacy LaunchD plist: $LAUNCH_PLIST"
  fi

  if local_mcp_healthy; then
    print -- "ok local MCP health"
  else
    print -- "info local MCP is not currently reachable"
  fi
  if pid_alive "$SUPERVISOR_PID_FILE"; then
    print -- "ok supervisor process"
  else
    print -- "info supervisor process is not currently running"
  fi
  if pid_alive "$TUNNEL_PID_FILE"; then
    print -- "ok reverse SSH tunnel process"
  else
    print -- "info reverse SSH tunnel process is not currently running"
  fi
  return "$failed"
}

case "${1:-status}" in
  install)
    install_cli
    install_launchd
    ;;
  run) run_foreground ;;
  start) start_supervisor ;;
  stop) stop_all ;;
  restart)
    if [[ "$NODE_MODE" == "persistent" && -f "$LAUNCH_PLIST" ]]; then
      launchctl kickstart -k "gui/$(id -u)/$LAUNCH_LABEL"
    else
      stop_all
      sleep 0.5
      start_supervisor
    fi
    ;;
  status) status ;;
  doctor) doctor ;;
  uninstall-persistence) uninstall_persistence ;;
  *) print -u2 -- "usage: neo-node [install|run|start|stop|restart|status|doctor|uninstall-persistence]"; exit 64 ;;
esac
