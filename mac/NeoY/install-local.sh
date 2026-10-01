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

identity="$(
  security find-identity -v -p codesigning |
    sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' |
    head -1
)"

if [[ -z "$identity" ]]; then
  print -u2 "NeoY local install requires a valid Apple Development signing identity."
  exit 1
fi

xcodegen generate --spec "$HERE/project.yml"
xcodebuild -project "$PROJECT" -scheme NeoY -configuration Debug \
  -derivedDataPath "$DERIVED" build

mkdir -p "$APP/Contents/Resources"
cp "$HERE/Resources/Scripts/runtime-control.sh" "$APP/Contents/Resources/runtime-control.sh"
chmod 755 "$APP/Contents/Resources/runtime-control.sh"

codesign --force --deep --sign "$identity" \
  --entitlements "$ENTITLEMENTS" --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

launchctl bootout "gui/$UID/$LAUNCH_LABEL" 2>/dev/null || true
killall NeoY 2>/dev/null || true
rm -rf "$DEST.new"
ditto "$APP" "$DEST.new"
rm -rf "$DEST"
mv "$DEST.new" "$DEST"

RUNTIME="$DEST/Contents/Resources/runtime-control.sh"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/.neoy"

# NeoY itself is always supervised by macOS launchd. PM2 is reserved for
# NeoY-managed background/feature services and is invoked through npx.
if command -v npx >/dev/null 2>&1; then
  npx --yes pm2 delete neoy >/dev/null 2>&1 || true
  npx --yes pm2 save --force >/dev/null 2>&1 || true
else
  print -u2 "warning: npx not found; NeoY will run, but PM2-managed feature services are unavailable"
fi
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
launchctl bootstrap "gui/$UID" "$LAUNCH_PLIST"
launchctl kickstart -k "gui/$UID/$LAUNCH_LABEL"
STARTUP_MODE="launch-agent-keepalive"

echo "Installed $DEST; startup mode: $STARTUP_MODE"
codesign -d -r- "$DEST" 2>&1 | tail -1
