# PhoneBridge — Handoff for mac111 (fix device install)

> Goal: get `PhoneBridge.app` installed on the iPhone 17 plugged into this Mac (mac111), launch it, and verify its MCP server answers from the LAN. Everything else is DONE — only the Mac↔phone install link is broken.

## 0. Context (what this app is)

`neox` repo was repurposed (branch `phonebridge`) into a **headless MCP server app**: no human UI except a status screen; the phone exposes `photos_search` / `photos_export` / `device_info` as MCP tools over WiFi on port 9223. Code is finished and compiles. Two repos, two branches:

- `/Users/chengli/Workspace/free2/neox` — branch `phonebridge`, project `PhoneBridge.xcodeproj`, scheme `PhoneBridgeApp`, bundle `com.neox.app`
- `/Users/chengli/Workspace/free2/copilot-ios` — branch `main` (has the shared packages; `AppAgent` = MCP server, `PhoneBridge` = the tools)

**The only remaining task**: install → launch → health check.

## 1. What's already working on THIS mac

| item | state |
|---|---|
| Signing identity | ✅ `iPhone Developer: Created via API (XQ45Y3FJUD)` — valid, in login keychain (minted via App Store Connect API; see §5 scripts) |
| WWDR intermediates | ✅ G3/G4/G5 imported (G3 was the one needed — the new cert chains to G3) |
| Provisioning profile | ✅ `PhoneBridge-Dev` (id `QL7J5K8T3V`) at `~/Library/MobileDevice/Provisioning Profiles/QL7J5K8T3V.mobileprovision` — includes cert + device + `com.neox.app` |
| Compiled app | ✅ `~/Workspace/free2/neox/build-device/DerivedData/Build/Products/Debug-iphoneos/PhoneBridge.app` |
| Signed? | ⚠️ **Partially** — the main binary is signed+verified (`codesign --verify --deep` → OK), but xcodebuild failed signing `PhoneBridge.debug.dylib`, so the `.app` is NOT Xcode-clean-signed. Current signature was applied manually with `--deep` + entitlements from the profile (script in §5). If install complains, re-run that sign script. |
| Keychain password | `o7a@bj` |
| ASC API key | `~/.private_keys/AuthKey_XQ45Y3FJUD.p8`, issuer `f5eefdb4-5b3c-4d6f-890c-70787b2214d0` |

## 2. The blocker — exactly what happens

- `xcrun devicectl list devices` shows iPhone 17 oscillating between `unavailable` / `connecting` / occasionally `available (paired)` / once `connected`.
- When `connecting`/`unavailable`, any `devicectl device ...` command **hangs forever** (no timeout).
- When it briefly went `connected`, an install attempt transferred **0 bytes** and stalled 13+ min; log finally showed:
  ```
  An unknown error occurred. (com.apple.dt.CoreDeviceError error -1 (0xFFFFFFFF))
  Could not allocate a resource. (com.apple.mobiledevice error -402653181 (0xE8000003))
  ```
- `xcodebuild -destination 'id=FC6AEF41-...'` fails with "developer disk image could not be mounted" — that's why builds use `-destination 'generic/platform=iOS'` (correct approach; install doesn't need the DDI, devicectl does the install).

`0xE8000003` (`kAMDResourceError`) + tunnel collapse on transfer = device-link resource issue, commonly fixed by: real cable/port change, trust re-establish, or reboot of phone and/or Mac. NOT a code/signing problem.

## 3. Device identifiers (both work in devicectl, CoreDevice id preferred)

- CoreDevice UDID: `FC6AEF41-F3A8-5176-8FEB-841232FF2237`
- Legacy UDID: `00008150-000449D93620401C`
- iOS 26.5.2 · developer mode ON · pairingState `paired` · macOS 26.2 · Xcode 26.6

## 4. Recovery playbook (run on mac111, in order)

```bash
# 0. Reset the wedged CoreDevice stack (this fixed 'connecting' → 'available (paired)' before)
pkill -9 -f "devicectl device install" 2>/dev/null
sudo pkill -9 CoreDeviceService 2>/dev/null
sleep 3
xcrun devicectl list devices --timeout 15000   # want: available (paired) or connected

# 1. Sanity: tunnel check (must NOT hang; if it hangs, go to step 5)
xcrun devicectl device info details --device FC6AEF41-F3A8-5176-8FEB-841232FF2237 | grep -i tunnel

# 2. Install (30 s when healthy; if it hangs >3 min, kill and go to step 5)
xcrun devicectl device install app --device FC6AEF41-F3A8-5176-8FEB-841232FF2237 \
  ~/Workspace/free2/neox/build-device/DerivedData/Build/Products/Debug-iphoneos/PhoneBridge.app

# 3. Launch
xcrun devicectl device process launch --device FC6AEF41-F3A8-5176-8FEB-841232FF2237 com.neox.app

# 4. Health check from any machine on the LAN (phone IP shown on the app's status screen,
#    was 10.0.0.81 before; port fixed 9223):
curl --max-time 5 http://<PHONE_IP>:9223/                      # → {"mcp_endpoint":"/mcp",...}
curl --max-time 5 -X POST http://<PHONE_IP>:9223/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
# Then photos flow: tools/call photos_search → photos_export {ids:[...]} → curl the /files/<name> URL.

# 5. If still stuck (escalation ladder):
#    a. On phone: Settings → General → VPN & Device Management → Developer Mode OFF → ON (phone reboots)
#    b. Different USB port DIRECTLY on the Mac (no hub) + different cable; re-tap Trust
#    c. Reboot the phone (hold side button)
#    d. Reboot mac111 (clears usbmuxd/CoreDevice fully)
#    e. macOS 26.6.2 update is pending — known CoreDevice fixes; `softwareupdate -ia` if all else fails
```

## 5. Scripts already on this mac (reusable)

- `/tmp/fixjwt.py` — App Store Connect JWT maker (ES256, correct 18-min window, **uses `time.time()`** — do not "fix" back to `datetime.utcnow()`, that bug cost an hour: naive-UTC-as-local shifted `iat` +8h → 401s).
  ```bash
  python3 /tmp/fixjwt.py XQ45Y3FJUD f5eefdb4-5b3c-4d6f-890c-70787b2214d0 ~/.private_keys/AuthKey_XQ45Y3FJUD.p8
  # token → /tmp/pb-jwt.token (valid ~18 min)
  ```
- `/tmp/mint2.sh` — mints + imports a new dev cert (CSR → ASC API → p12 → keychain). Note: `displayName` is NOT allowed on cert CREATE; keychain import needs `security unlock-keychain` in the SAME session.
- `/tmp/mint-profile.sh` — creates + installs the `PhoneBridge-Dev` profile (bundleId `7N68SAPYRK` + cert `W23FFM7GMA` + device `ZHM98FB8V8`). Device lookup uses the **legacy** UDID `00008150-000449D93620401C` (the CoreDevice id is rejected by the API).
- Manual-sign script (if the app needs re-signing):
  ```bash
  APP=~/Workspace/free2/neox/build-device/DerivedData/Build/Products/Debug-iphoneos/PhoneBridge.app
  cp ~/Library/MobileDevice/"Provisioning Profiles"/QL7J5K8T3V.mobileprovision "$APP/embedded.mobileprovision"
  security cms -D -i "$APP/embedded.mobileprovision" > /tmp/p.xml
  python3 -c "import plistlib;p=plistlib.load(open('/tmp/pb-profile.plist','rb')) if False else None"  # or re-extract from /tmp/p.xml
  codesign --force --deep --sign "iPhone Developer: Created via API (XQ45Y3FJUD)" \
    --entitlements /tmp/pb-ent.plist "$APP"
  ```
  (`/tmp/pb-ent.plist` = profile entitlements + `get-task-allow=true`; regenerate from `/tmp/p.xml` if missing.)

## 6. Build from scratch (if needed)

```bash
cd ~/Workspace/free2/neox
# keychain prep FIRST, own session:
security unlock-keychain -p 'o7a@bj' ~/Library/Keychains/login.keychain-db && \
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k 'o7a@bj' ~/Library/Keychains/login.keychain-db >/dev/null

xcodebuild -project PhoneBridge.xcodeproj -scheme PhoneBridgeApp -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath build-device/DerivedData \
  PROVISIONING_PROFILE_SPECIFIER="PhoneBridge-Dev" CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="iPhone Developer: Created via API (XQ45Y3FJUD)" build
# (the CodeSign debug-dylib step may fail under headless runs — the manual --deep sign in §5 covers it)
```

## 7. Verification checklist (the actual acceptance)

1. App launches on phone → status screen shows **Running** + LAN IP + request log
2. Phone asks **Photos permission** on first tool call → tap Allow (or the Allow button on the status screen)
3. From desktop:
   ```bash
   curl -s http://<PHONE_IP>:9223/ | jq
   curl -s -X POST http://<PHONE_IP>:9223/mcp -H 'Content-Type: application/json' \
     -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | jq '.result.tools[].name'
   # expect: ["device_info","photos_export","photos_search"]
   ```
4. Export flow: `photos_search {media_type:"video", days:30, limit:3}` → take `id`s → `photos_export {ids:[...], preset:"720p"}` → `curl -C - -o out.mp4 http://<IP>:9223/files/<file>` (Range/resume works — this is the big-file path).

## 8. Gotchas learned (don't rediscover)

- `devicectl` hangs forever when tunnel is down — **always** wrap with a timeout; `pkill -9 devicectl` after.
- Long `ssh '<unlock-keychain && xcodebuild>'` one-liners deadlock the channel; run keychain prep and build as separate ssh calls.
- ASC API: cert CREATE takes no `displayName`; profile CREATE 409s if device registered under the other UDID; JWT `exp−iat` must be ≤ 20 min and `iat` must be real epoch (`time.time()`).
- The app itself is tiny (~2 MB, no ffmpeg/CameraKit) — install slowness is NEVER the app, it's the tunnel.
