# TestFlight and Direct Download Checklist

Use this checklist before closing the release-foundation GitHub issues.

## Local validation

```bash
swift build
swift test
./scripts/build_dev_app_bundle.sh release
./scripts/install_app_bundle.sh
FORCE_PLAIN_DMG=1 NOTARIZE_DMG=0 ./scripts/build_dmg.sh release
./scripts/release_doctor.sh
```

Expected local result:

- The app bundle exists at `.build/AppBundle/MinuteWave.app`.
- `codesign --verify --deep --strict .build/AppBundle/MinuteWave.app` passes.
- The app contains `Contents/Resources/PrivacyInfo.xcprivacy`.
- The app contains localized `InfoPlist.strings` files under `Contents/Resources/*.lproj`.
- The release app has the sandbox, microphone, user-selected file, and network-client entitlements.
- The local DMG verifies with `hdiutil verify`.
- `/Applications/MinuteWave.app` is certificate-signed with the same Team ID as the built app.

Ad-hoc signing and missing notarization are acceptable only for local validation.
Do not use an older `/Applications/MinuteWave.app` for TCC validation. macOS can show a stale Screen & System Audio Recording grant for one `MinuteWave.app` while the running app has a different code-signing identity.

## Direct download release

Use Developer ID signing and notarization:

```bash
SIGNING_IDENTITY="Developer ID Application: Your Company (TEAMID)" \
ENABLE_HARDENED_RUNTIME=1 \
NOTARIZE_DMG=1 \
APPLE_NOTARY_APPLE_ID="apple-id@example.com" \
APPLE_NOTARY_TEAM_ID="TEAMID" \
APPLE_NOTARY_PASSWORD="@keychain:AC_PASSWORD" \
./scripts/build_dmg.sh release

STRICT_DISTRIBUTION=1 \
SIGNING_IDENTITY="Developer ID Application: Your Company (TEAMID)" \
APPLE_NOTARY_APPLE_ID="apple-id@example.com" \
APPLE_NOTARY_TEAM_ID="TEAMID" \
APPLE_NOTARY_PASSWORD="@keychain:AC_PASSWORD" \
./scripts/release_doctor.sh
```

Expected distribution result:

- The app is certificate-signed, not ad-hoc signed.
- Hardened runtime is enabled.
- The DMG has a stapled notarization ticket.
- Gatekeeper accepts the DMG with:

```bash
spctl -a -vv -t open --context context:primary-signature dist/MinuteWave-macOS.dmg
```

For GitHub-hosted releases, configure the secrets in
`docs/GitHubActionsReleaseSecrets.md`. Tag pushes matching `v*.*.*` now require
Developer ID signing and notarization instead of falling back to ad-hoc signing.

## TestFlight readiness

The local Swift Package Manager bundle is useful for TCC and DMG validation, but TestFlight still requires an Apple archive/export path. Before marking TestFlight work complete:

- Create or open the native macOS app target/archive flow in Xcode, or run the
  `TestFlight Package` GitHub Actions workflow.
- Use bundle identifier `com.vepando.minutewave`.
- Use the same entitlements from `config/MinuteWave.entitlements`.
- Include `Sources/AINoteTakerApp/Resources/PrivacyInfo.xcprivacy`.
- Archive with an Apple Distribution/App Store signing identity.
- Validate the archive in Xcode Organizer or App Store Connect.
- Run an internal TestFlight install on a clean macOS user account.

The repository includes `scripts/build_testflight_pkg.sh` for the workflow. A
package-only workflow run requires Apple Distribution and 3rd Party Mac Developer
Installer credentials. App Store Connect credentials are required when
`validate` or `upload` is enabled. A local `Apple Development` certificate is not
enough for TestFlight upload.

## TCC smoke test

Run this with the signed app identity that users will receive:

```bash
RESET_TCC=1 ./scripts/install_app_bundle.sh
open "/Applications/MinuteWave.app"
```

Then verify:

- Microphone permission prompt appears and granted state is detected.
- Screen Recording permission prompt/settings flow appears for system audio mode.
- After granting Screen Recording in System Settings and restarting the app, MinuteWave does not report a stale missing permission.
- Microphone-only capture still works when Screen Recording is denied.
