#!/usr/bin/env bash
# remote-deploy.sh — Build, install, and launch Neox on iPhone 12 mini
#                     via the remote Mac (10.0.0.111) that has USB connection.
#
# Prerequisites:
#   1. SSH key auth: ssh-copy-id lir@10.0.0.111
#   2. Remote Mac has Xcode installed with iOS SDK
#   3. iPhone 12 mini connected to remote Mac (USB or WiFi)
#   4. Apple API key (.p8) exists on remote Mac
#
# Usage:
#   ./remote-deploy.sh --setup-ssh       # one-time: copy SSH key to remote Mac
#   ./remote-deploy.sh                   # full: sync → build → install → launch → health-check
#   ./remote-deploy.sh --build-only      # sync + build (no install/launch)
#   ./remote-deploy.sh --install-only    # install + launch (skip build)
#   ./remote-deploy.sh --health          # just health-check the running app
#   ./remote-deploy.sh --snapshot        # take AppAgent snapshot
#   ./remote-deploy.sh --mcp CMD [ARGS]  # send arbitrary MCP tool call

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────
REMOTE_HOST="${REMOTE_HOST:-10.0.0.111}"
REMOTE_USER="${REMOTE_USER:-chengli}"
REMOTE_WORKSPACE="${REMOTE_WORKSPACE:-}"  # auto-detected if empty

DEVICE_UDID="${DEVICE_UDID:-FC6AEF41-F3A8-5176-8FEB-841232FF2237}"   # iPhone 17 (default); override with DEVICE_UDID=...
DEVICE_IP="${DEVICE_IP:-10.0.0.81}"       # iPhone LAN IP (override with DEVICE_IP=...)
MCP_PORT="9223"                           # AppAgent MCP server port

BUNDLE_ID="com.neox.app"
SCHEME="Neox"
CONFIGURATION="Debug"
TEAM_ID="JABNLDLN8G"

AUTH_KEY_ID="XQ45Y3FJUD"
AUTH_KEY_ISSUER="f5eefdb4-5b3c-4d6f-890c-70787b2214d0"
# Resolved on remote Mac relative to workspace

MONOREPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NEOX_ROOT="${MONOREPO_ROOT}/neox"

# ── Colors ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}▸${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
fail()  { echo -e "${RED}✗${NC} $*" >&2; exit 1; }

# ── SSH helper ─────────────────────────────────────────────────────────
_ssh() {
    ssh -o ConnectTimeout=10 -o BatchMode=yes "${REMOTE_USER}@${REMOTE_HOST}" "$@"
}

# ── Setup SSH key auth ─────────────────────────────────────────────────
setup_ssh() {
    info "Setting up SSH key auth to ${REMOTE_USER}@${REMOTE_HOST}..."

    # Generate key if missing
    if [[ ! -f ~/.ssh/id_ed25519 ]]; then
        info "Generating SSH key..."
        ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
    fi

    # Copy public key (will prompt for password once)
    ssh-copy-id -o StrictHostKeyChecking=accept-new "${REMOTE_USER}@${REMOTE_HOST}"

    # Verify
    if _ssh 'echo SSH_OK' 2>/dev/null | grep -q SSH_OK; then
        ok "SSH key auth configured successfully"
    else
        fail "SSH key auth setup failed"
    fi
}

# ── Detect remote workspace ───────────────────────────────────────────
detect_remote_workspace() {
    if [[ -n "$REMOTE_WORKSPACE" ]]; then return; fi

    info "Detecting remote workspace path..."
    # Try common paths
    for candidate in \
        "/Users/${REMOTE_USER}/Workspace/free2" \
        "/Users/chengli/Workspace/free2" \
        "$HOME/Workspace/free2"; do
        if _ssh "test -d '${candidate}/neox'" 2>/dev/null; then
            REMOTE_WORKSPACE="$candidate"
            ok "Remote workspace: ${REMOTE_WORKSPACE}"
            return
        fi
    done

    # Fallback: find it
    REMOTE_WORKSPACE=$(_ssh "find /Users -maxdepth 4 -name 'Neox.xcodeproj' -type d 2>/dev/null | head -1 | sed 's|/neox/Neox.xcodeproj||'" || true)
    if [[ -z "$REMOTE_WORKSPACE" ]]; then
        fail "Cannot find workspace on remote Mac. Set REMOTE_WORKSPACE explicitly."
    fi
    ok "Remote workspace: ${REMOTE_WORKSPACE}"
}

# ── Phase 1: Sync code ────────────────────────────────────────────────
sync_code() {
    detect_remote_workspace

    info "Syncing code to ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_WORKSPACE}/ ..."

    # Ensure remote dirs exist
    _ssh "mkdir -p '${REMOTE_WORKSPACE}/neox' '${REMOTE_WORKSPACE}/copilot-ios'"

    # Sync copilot-ios (the SPM packages — needed for build)
    rsync -az --delete \
        --exclude '.build/' \
        --exclude 'build/' \
        --exclude 'DerivedData/' \
        --exclude '.swiftpm/' \
        "${MONOREPO_ROOT}/copilot-ios/" \
        "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_WORKSPACE}/copilot-ios/"

    # Sync neox app
    rsync -az --delete \
        --exclude 'build-device/' \
        --exclude 'DerivedData/' \
        --exclude '.build/' \
        "${NEOX_ROOT}/" \
        "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_WORKSPACE}/neox/"

    # Fix symlink on remote (neox/copilot-ios → ../copilot-ios)
    _ssh "cd '${REMOTE_WORKSPACE}/neox' && rm -f copilot-ios && ln -s ../copilot-ios copilot-ios"

    ok "Code synced"
}

# ── Phase 2: Build ─────────────────────────────────────────────────────
build_app() {
    detect_remote_workspace
    local REMOTE_NEOX="${REMOTE_WORKSPACE}/neox"
    local AUTH_KEY_PATH="${REMOTE_WORKSPACE}/.tmp/AuthKey_${AUTH_KEY_ID}.p8"

    info "Building ${SCHEME} on remote Mac..."

    # Unlock keychain for code signing over SSH
    # Without this + set-key-partition-list, codesign fails with errSecInternalComponent
    if [[ -z "${KEYCHAIN_PASSWORD:-}" ]]; then
        warn "KEYCHAIN_PASSWORD not set — code signing may fail over SSH."
        warn "Run with: KEYCHAIN_PASSWORD=xxx ./remote-deploy.sh"
    fi

    # Build with up to 3 retries (codesign sometimes fails with transient errSecInternalComponent
    # under parallel xcodebuild signing — re-running picks up cached objects and only re-signs the failed bits)
    local build_cmd
    # CRITICAL: keychain unlock + partition-list MUST be in same SSH session as xcodebuild,
    # otherwise codesign children can't access the private key (errSecInternalComponent)
    build_cmd=""
    if [[ -n "${KEYCHAIN_PASSWORD:-}" ]]; then
        build_cmd="security unlock-keychain -p '${KEYCHAIN_PASSWORD}' ~/Library/Keychains/login.keychain-db && \
security set-keychain-settings -t 7200 -l ~/Library/Keychains/login.keychain-db && \
security set-key-partition-list -S apple-tool:,apple:,unsigned: -s -k '${KEYCHAIN_PASSWORD}' ~/Library/Keychains/login.keychain-db > /dev/null 2>&1; "
    fi
    build_cmd="${build_cmd}cd '${REMOTE_NEOX}' && xcodebuild -project Neox.xcodeproj -scheme ${SCHEME} -configuration ${CONFIGURATION} -destination 'id=${DEVICE_UDID}' -derivedDataPath build-device/DerivedData -allowProvisioningUpdates"
    if _ssh "test -f '${AUTH_KEY_PATH}'" 2>/dev/null; then
        build_cmd="${build_cmd} -authenticationKeyID ${AUTH_KEY_ID} -authenticationKeyIssuerID ${AUTH_KEY_ISSUER} -authenticationKeyPath '${AUTH_KEY_PATH}'"
    fi
    build_cmd="${build_cmd} build"

    local attempt=0
    local max_attempts=3
    local build_ok=false
    while (( attempt < max_attempts )); do
        ((attempt++))
        info "Build attempt ${attempt}/${max_attempts}..."
        local cmd_this="${build_cmd}"
        # Last attempt: serialize codesign to avoid keychain race (errSecInternalComponent under parallel signing)
        if (( attempt == max_attempts )); then
            warn "Final attempt: serializing with -jobs 1"
            cmd_this="${build_cmd/xcodebuild/xcodebuild -jobs 1}"
        fi
        if _ssh "${cmd_this} 2>&1" | tee /dev/stderr | tail -5 | grep -q 'BUILD SUCCEEDED'; then
            build_ok=true
            break
        fi
        warn "Build attempt ${attempt} failed — retrying"
        # Re-unlock + re-set partition list before retry
        _ssh "security unlock-keychain -p '${KEYCHAIN_PASSWORD}' ~/Library/Keychains/login.keychain-db && \
              security set-key-partition-list -S apple-tool:,apple:,unsigned: -s -k '${KEYCHAIN_PASSWORD}' ~/Library/Keychains/login.keychain-db > /dev/null 2>&1 || true"
    done
    [[ "$build_ok" == true ]] || fail "Build failed after ${max_attempts} attempts (check output above)"

    # Verify .app exists
    if ! _ssh "test -d '${REMOTE_NEOX}/build-device/DerivedData/Build/Products/${CONFIGURATION}-iphoneos/${SCHEME}.app'"; then
        fail "Build failed — .app bundle not found"
    fi

    ok "Build succeeded"
}

# ── Phase 3: Install ──────────────────────────────────────────────────
install_app() {
    detect_remote_workspace
    local REMOTE_NEOX="${REMOTE_WORKSPACE}/neox"
    local APP_PATH="${REMOTE_NEOX}/build-device/DerivedData/Build/Products/${CONFIGURATION}-iphoneos/${SCHEME}.app"

    info "Installing to device ${DEVICE_UDID}..."

    _ssh "xcrun devicectl device install app \
        --device '${DEVICE_UDID}' \
        '${APP_PATH}'" 2>&1 || warn "Install may have failed — continuing to launch"

    ok "Installed"
}

# ── Phase 4: Launch ───────────────────────────────────────────────────
launch_app() {
    info "Launching ${BUNDLE_ID}..."

    # Kill existing instance first
    _ssh "xcrun devicectl device process terminate \
        --device '${DEVICE_UDID}' \
        '${BUNDLE_ID}' 2>/dev/null || true"

    sleep 1

    _ssh "xcrun devicectl device process launch \
        --device '${DEVICE_UDID}' \
        '${BUNDLE_ID}'" 2>&1 || warn "Launch command returned non-zero"

    ok "App launched"
}

# ── Phase 5: Health check (MCP) ──────────────────────────────────────
health_check() {
    info "Waiting for AppAgent MCP server at ${DEVICE_IP}:${MCP_PORT}..."

    local max_attempts=30
    local attempt=0

    while (( attempt < max_attempts )); do
        ((attempt++))
        local result
        result=$(curl -s -m 3 -X POST "http://${DEVICE_IP}:${MCP_PORT}/mcp" \
            -H 'Content-Type: application/json' \
            -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"app_agent","arguments":{"command":"snapshot"}}}' \
            2>/dev/null || true)

        if echo "$result" | grep -q '"result"'; then
            ok "AppAgent is responding!"
            echo ""
            echo "$result" | python3 -c "
import sys, json
try:
    r = json.load(sys.stdin)
    text = r['result']['content'][0]['text']
    for line in text.split('\n')[:15]:
        print(line)
except: print(r)
" 2>/dev/null || echo "$result" | head -5
            echo ""
            echo -e "${GREEN}MCP endpoint: http://${DEVICE_IP}:${MCP_PORT}/mcp${NC}"
            return 0
        fi

        if (( attempt % 5 == 0 )); then
            info "Attempt ${attempt}/${max_attempts} — waiting..."
        fi
        sleep 2
    done

    fail "AppAgent did not respond after ${max_attempts} attempts"
}

# ── MCP tool call helper ──────────────────────────────────────────────
mcp_call() {
    local command="$1"; shift
    local args="{\"command\":\"${command}\""

    # Parse remaining key=value pairs
    while (( $# > 0 )); do
        local key="${1%%=*}"
        local val="${1#*=}"
        args="${args},\"${key}\":\"${val}\""
        shift
    done
    args="${args}}"

    local payload="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"app_agent\",\"arguments\":${args}}}"

    curl -s -m 10 -X POST "http://${DEVICE_IP}:${MCP_PORT}/mcp" \
        -H 'Content-Type: application/json' \
        -d "$payload" | python3 -c "
import sys, json
try:
    r = json.load(sys.stdin)
    text = r['result']['content'][0]['text']
    print(text)
except Exception as e:
    print(json.dumps(r, indent=2) if 'r' in dir() else f'Error: {e}')
" 2>/dev/null
}

# ── Main ──────────────────────────────────────────────────────────────
main() {
    local mode="${1:-full}"

    case "$mode" in
        --setup-ssh)
            setup_ssh
            ;;
        --build-only)
            sync_code
            build_app
            ;;
        --install-only)
            install_app
            launch_app
            health_check
            ;;
        --health)
            health_check
            ;;
        --snapshot)
            mcp_call snapshot
            ;;
        --mcp)
            shift
            if (( $# == 0 )); then
                fail "Usage: $0 --mcp <command> [key=value ...]"
            fi
            mcp_call "$@"
            ;;
        full|"")
            info "Full deploy: sync → build → install → launch → health-check"
            echo ""
            sync_code
            build_app
            install_app
            launch_app
            health_check
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo -e "${GREEN}Neox is running on iPhone 12 mini${NC}"
            echo -e "  MCP endpoint:  ${BLUE}http://${DEVICE_IP}:${MCP_PORT}/mcp${NC}"
            echo -e "  VS Code config:  Add to .vscode/mcp.json:"
            echo '    {"servers":{"neox":{"url":"http://'"${DEVICE_IP}"':'"${MCP_PORT}"'/mcp"}}}'
            echo ""
            echo "  Quick commands:"
            echo "    $0 --snapshot              # screen snapshot"
            echo "    $0 --mcp tap ref=r3        # tap Chat tab"
            echo "    $0 --mcp type ref=r5 text='hello'"
            echo "    $0 --mcp screenshot        # base64 JPEG"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            ;;
        *)
            echo "Usage: $0 [--setup-ssh|--build-only|--install-only|--health|--snapshot|--mcp CMD [ARGS]]"
            exit 1
            ;;
    esac
}

main "$@"
