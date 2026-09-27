#!/bin/zsh
set -euo pipefail

HERE="${0:A:h}"
PROJECT="$HERE/NeoY.xcodeproj"
DERIVED="$HERE/build"
APP="$DERIVED/Build/Products/Debug/NeoY.app"
DEST="/Applications/NeoY.app"
ENTITLEMENTS="$HERE/Resources/NeoY.entitlements"

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

codesign --force --deep --sign "$identity" \
  --entitlements "$ENTITLEMENTS" --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

killall NeoY 2>/dev/null || true
rm -rf "$DEST.new"
ditto "$APP" "$DEST.new"
rm -rf "$DEST"
mv "$DEST.new" "$DEST"
osascript -e 'tell application "NeoY" to activate'

echo "Installed $DEST"
codesign -d -r- "$DEST" 2>&1 | tail -1
