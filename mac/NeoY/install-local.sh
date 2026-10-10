#!/bin/zsh
set -euo pipefail

HERE="${0:A:h}"
PROJECT="$HERE/NeoY.xcodeproj"
DERIVED="$HERE/build"
APP="$DERIVED/Build/Products/Debug/NeoY.app"
DEST="/Applications/NeoY.app"
ENTITLEMENTS="$HERE/Resources/NeoY.entitlements"
LAUNCH_LABEL="com.neox.neoy.keepalive"
LAUNCH_PLIST="$HOME/Library/LaunchAgents/$LAUNCH_LABEL.plist"
WATCHDOG_LABEL="com.neox.neoy.upgrade-watchdog"
WATCHDOG_PLIST="$HOME/Library/LaunchAgents/$WATCHDOG_LABEL.plist"
WATCHDOG="$HOME/Library/Application Support/NeoY/bin/upgrade-watchdog.sh"
BACKUP="/Applications/NeoY.previous.app"
UPGRADE_LOG="$HOME/Library/Logs/NeoY/upgrade.log"
UPGRADE_TRIGGER="$HOME/Library/Application Support/NeoY/upgrade.trigger"

identity="$(
  security find-identity -v -p codesigning |
    sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' |
    head -1
)"

if [[ -z "$identity" ]]; then
  print -u2 "NeoY local install requires a valid Apple Development signing identity."
  exit 1
fi

if command -v node >/dev/null 2>&1; then
  npm test --prefix "$HERE/Runtime"
fi

xcodegen generate --spec "$HERE/project.yml"
rm -rf "$APP"
xcodebuild -project "$PROJECT" -scheme NeoY -configuration Debug \
  -derivedDataPath "$DERIVED" build

codesign --force --deep --sign "$identity" \
  --entitlements "$ENTITLEMENTS" --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

# Stage the candidate and install a rollback watchdog before touching the working app.
mkdir -p "$HOME/Library/Application Support/NeoY/bin" "$HOME/Library/Logs/NeoY"
cp "$HERE/Resources/Scripts/upgrade-watchdog.sh" "$WATCHDOG"
chmod 755 "$WATCHDOG"
rm -rf "$DEST.new"
ditto "$APP" "$DEST.new"
EXPECTED_HASH="$(shasum -a 256 "$DEST.new/Contents/MacOS/NeoY" | awk '{print $1}')"

# Keep exactly one known-good previous app. Never delete the current working app
# until the fully built and signed candidate has been staged.
rm -rf "$BACKUP"
if [[ -d "$DEST" ]]; then ditto "$DEST" "$BACKUP"; fi

# Arm the watchdog under launchd BEFORE the working NeoY is stopped. The watchdog
# waits for UPGRADE_TRIGGER, so it cannot declare success against the old app.
rm -f "$UPGRADE_TRIGGER"
launchctl bootout "gui/$UID/$WATCHDOG_LABEL" 2>/dev/null || true
cat > "$WATCHDOG_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$WATCHDOG_LABEL</string>
  <key>ProgramArguments</key><array><string>$WATCHDOG</string></array>
  <key>RunAtLoad</key><true/>
  <key>EnvironmentVariables</key><dict>
    <key>NEOY_EXPECTED_HASH</key><string>$EXPECTED_HASH</string>
    <key>NEOY_UPGRADE_LOG</key><string>$UPGRADE_LOG</string>
    <key>NEOY_TRIGGER_FILE</key><string>$UPGRADE_TRIGGER</string>
  </dict>
  <key>StandardOutPath</key><string>$HOME/.neoy/upgrade-watchdog.out.log</string>
  <key>StandardErrorPath</key><string>$HOME/.neoy/upgrade-watchdog.err.log</string>
</dict></plist>
PLIST
plutil -lint "$WATCHDOG_PLIST" >/dev/null
launchctl bootstrap "gui/$UID" "$WATCHDOG_PLIST"

launchctl bootout "gui/$UID/$LAUNCH_LABEL" 2>/dev/null || true
killall NeoY 2>/dev/null || true
rm -rf "$DEST"
mv "$DEST.new" "$DEST"

# Runtime code is loaded directly from the NeoY repo; remove all legacy runtime copies/overrides.
rm -rf "$HOME/Library/Application Support/NeoY/runtime"
rm -f "$HOME/Library/Application Support/NeoY/runtime-source"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/.neoy"

# NeoY and its cloudflared child are supervised without PM2. Remove obsolete
# PM2 entries once during installation; optional products may still use PM2.
for process_name in neoy neoy-tunnel neoy-runtime-gateway neoy-mcp-gateway; do
  npx --yes pm2 delete "$process_name" >/dev/null 2>&1 || true
done
npx --yes pm2 save --force >/dev/null 2>&1 || true
rm -f "$HOME/Library/Application Support/NeoY/neoy-pm2.config.cjs"

cat > "$LAUNCH_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LAUNCH_LABEL</string>
  <key>ProgramArguments</key><array><string>$DEST/Contents/MacOS/NeoY</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>ThrottleInterval</key><integer>3</integer>
  <key>StandardOutPath</key><string>$HOME/.neoy/launchd.out.log</string>
  <key>StandardErrorPath</key><string>$HOME/.neoy/launchd.err.log</string>
</dict></plist>
PLIST
plutil -lint "$LAUNCH_PLIST" >/dev/null

# Purge obsolete bridge-era launchd environment before NeoY starts. Child
# environment scrubbing remains defense-in-depth, but launchd should be clean too.
for key in MAC_DEV_BRIDGE_PUBLIC_URL MAC_DEV_BRIDGE_HTTP_PORT MAC_DEV_BRIDGE_LOG_DIR MAC_DEV_BRIDGE_DATA_DIR; do
  launchctl unsetenv "$key" 2>/dev/null || true
done

launchctl bootstrap "gui/$UID" "$LAUNCH_PLIST"
launchctl kickstart -k "gui/$UID/$LAUNCH_LABEL"
STARTUP_MODE="launch-agent-keepalive"

# Signal the already-armed watchdog only after the candidate has been installed
# and launchd has been asked to start it. If this script dies before this point,
# the watchdog times out its arm phase and restores the previous app.
touch "$UPGRADE_TRIGGER"

echo "Installed $DEST; startup mode: $STARTUP_MODE"
codesign -d -r- "$DEST" 2>&1 | tail -1
