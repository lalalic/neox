# Neox TestFlight release

The repo owns the release target in `scripts/testflight.json`. The script uses the existing **App Store Connect team API key**, not Xcode's intermittent interactive Apple Accounts session. Do **not** commit `.p8` files, login cookies, JWTs, exported accounts, or Apple API responses with personal information.

From the Neox repository on Neo Master:

```bash
scripts/testflight.py doctor
scripts/testflight.py release --bump
# Or upload an existing, already archived build without rebuilding:
scripts/testflight.py release --archive runs/2026-11-13-testflight-17/Neox-0.1.0-17.xcarchive
# Read latest processing/compliance/group status; does not upload:
scripts/testflight.py status --build 17
# Once compliance is correctly classified, explicitly attach existing internal testers:
scripts/testflight.py status --build 17 --assign-group
```

`doctor` verifies matching App Store Connect app ID/bundle ID, key validity, highest uploaded build number, and local distribution certificate/profile compatibility. `doctor --offline` is available when Apple is down. The private key is resolved only from `~/.private_keys/AuthKey_<key_id>.p8` (override directory via `ASC_PRIVATE_KEYS_DIR`) and must be mode `0600`. `scripts/testflight.json` stores **identifiers, not credentials**. If the team, key, TestFlight group, or app ID changes, update that file once after verification in Apple's account; never search every directory or guess IDs.

`release` fails before uploading if the version/build number is not higher than the builds already registered at Apple. `--bump` automatically increases the local `Neox/Info.plist` build number, using the maximum of local and Apple build numbers, and archives Release with authenticated signing. It intentionally leaves the version change in Git's working tree for review and commit. Without `--bump`, it requires the committed build number to be new. `--archive` checks exact bundle ID and build identity before uploading. `--dry-run` tests read-only preflight without modifying source or uploading.

Export uses Xcode `-authenticationKeyPath`, `-authenticationKeyID`, and `-authenticationKeyIssuerID` with `-allowProvisioningUpdates`. This is the canonical path. **Do not retry export via Xcode GUI login when account selection fails.** If the cached profile omits the currently installed distribution certificate, authenticated automatic signing should obtain fresh assets; if Apple denies that, stop with the explicit signing error, do not revoke unrelated certificates or silently fall back to manual/Development signing.

The script keeps build/export logs and `ExportOptions.plist` under an owner-only `runs/testflight-*` directory. Upload completion, Apple processing `VALID`, internal group linkage, `IN_BETA_TESTING`, website compliance, and on-device TestFlight installation are **separate gates**. The script confirms Apple API state and links only the configured existing internal tester group after `VALID`; it never declares an export compliance exemption on its own. It returns nonzero when the internal group is not active. After upload, check [Neox AI TestFlight on App Store Connect](https://appstoreconnect.apple.com/apps/6761634486/testflight/ios) for the exact build's encryption compliance, group, and testers, then verify the iPhone shows and launches the build. This final website/phone gate is not automated by the command.

Test the release tool: `python3 -m unittest discover -s tests -p 'test_testflight.py' -v` and `scripts/testflight.py release --archive <archive> --dry-run`. All Apple network operations are read-only except the explicitly requested upload and the group assignment after a successful upload or `status --assign-group`.
