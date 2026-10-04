#!/bin/zsh
set -u

DEST="${NEOY_DEST:-/Applications/NeoY.app}"
BACKUP="${NEOY_BACKUP:-/Applications/NeoY.previous.app}"
LAUNCH_LABEL="${NEOY_LAUNCH_LABEL:-com.neox.neoy.keepalive}"
LAUNCH_PLIST="${NEOY_LAUNCH_PLIST:-$HOME/Library/LaunchAgents/$LAUNCH_LABEL.plist}"
PORT="${NEOY_PORT:-6767}"
STARTUP_TIMEOUT="${NEOY_STARTUP_TIMEOUT:-30}"
ROLLBACK_TIMEOUT="${NEOY_ROLLBACK_TIMEOUT:-20}"
LOG="${NEOY_UPGRADE_LOG:-$HOME/Library/Logs/NeoY/upgrade.log}"
EXPECTED_HASH="${NEOY_EXPECTED_HASH:-}"
HEALTH_URL="${NEOY_HEALTH_URL:-http://127.0.0.1:${PORT}/}"
TEST_MODE="${NEOY_TEST_MODE:-0}"
TRIGGER_FILE="${NEOY_TRIGGER_FILE:-$HOME/Library/Application Support/NeoY/upgrade.trigger}"
ARM_TIMEOUT="${NEOY_ARM_TIMEOUT:-20}"

mkdir -p "${LOG:h}"
log() { print -r -- "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*" >> "$LOG"; }
health_ok() {
  [[ -x "$DEST/Contents/MacOS/NeoY" ]] || return 1
  if [[ -n "$EXPECTED_HASH" ]]; then
    local actual
    actual="$(shasum -a 256 "$DEST/Contents/MacOS/NeoY" 2>/dev/null | awk '{print $1}')" || return 1
    [[ "$actual" == "$EXPECTED_HASH" ]] || return 1
  fi
  /usr/bin/curl -fsS --max-time 2 "$HEALTH_URL" 2>/dev/null | /usr/bin/grep -q '"mcp_endpoint"'
}
wait_for_health() {
  local timeout="$1" elapsed=0
  while (( elapsed < timeout )); do
    if health_ok; then return 0; fi
    sleep 1
    (( elapsed += 1 ))
  done
  return 1
}

log "watchdog armed expected_hash=${EXPECTED_HASH:-unknown}"
triggered=0
elapsed=0
while [[ ! -f "$TRIGGER_FILE" && $elapsed -lt $ARM_TIMEOUT ]]; do
  sleep 1
  (( elapsed += 1 ))
done
if [[ ! -f "$TRIGGER_FILE" ]]; then
  log "deployment trigger missing after ${ARM_TIMEOUT}s; treating upgrade as interrupted"
else
  rm -f "$TRIGGER_FILE"
  triggered=1
  log "deployment trigger observed; checking candidate health"
fi
if [[ $triggered -eq 1 && -f "$DEST/Contents/MacOS/NeoY" ]] && wait_for_health "$STARTUP_TIMEOUT"; then
  log "candidate healthy; keeping previous backup at $BACKUP"
  exit 0
fi

log "candidate failed health check; rolling back"
if [[ "$TEST_MODE" != "1" ]]; then
  launchctl bootout "gui/$UID/$LAUNCH_LABEL" >/dev/null 2>&1 || true
  killall NeoY >/dev/null 2>&1 || true
fi
if [[ ! -d "$BACKUP" ]]; then
  log "rollback impossible: backup missing at $BACKUP"
  exit 2
fi
rm -rf "$DEST.failed"
[[ -d "$DEST" ]] && mv "$DEST" "$DEST.failed"
mv "$BACKUP" "$DEST"
rm -rf "$DEST.failed"

if [[ "$TEST_MODE" != "1" ]]; then
  launchctl bootstrap "gui/$UID" "$LAUNCH_PLIST" >/dev/null 2>&1 || true
  launchctl kickstart -k "gui/$UID/$LAUNCH_LABEL" >/dev/null 2>&1 || true
fi
EXPECTED_HASH=""
if wait_for_health "$ROLLBACK_TIMEOUT"; then
  log "rollback healthy; restored previous NeoY.app"
  exit 0
fi
log "rollback attempted but previous NeoY.app did not become healthy"
exit 3
