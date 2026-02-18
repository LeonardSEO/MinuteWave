# MinuteWave - Local-First AI Meeting Copilot for macOS

<p align="center">
  <img src="icon-clean.png" alt="MinuteWave logo" width="220" />
</p>

<p align="center">
  Record meetings, transcribe speech, separate speakers, generate summaries, and chat with your transcript.
</p>

<p align="center">
  <a href="https://github.com/LeonardSEO/MinuteWave/actions/workflows/release.yml"><img src="https://img.shields.io/github/actions/workflow/status/LeonardSEO/MinuteWave/release.yml?style=for-the-badge" alt="Release workflow status"></a>
  <a href="https://github.com/LeonardSEO/MinuteWave/releases"><img src="https://img.shields.io/github/v/release/LeonardSEO/MinuteWave?style=for-the-badge" alt="Latest release"></a>
  <a href="https://github.com/LeonardSEO/MinuteWave/releases"><img src="https://img.shields.io/github/downloads/LeonardSEO/MinuteWave/total?style=for-the-badge" alt="Downloads"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge" alt="MIT License"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black?style=for-the-badge&logo=apple" alt="macOS 14+">
</p>

<p align="center">
  <a href="https://github.com/LeonardSEO/MinuteWave/releases/latest/download/MinuteWave-macOS.dmg">
    <img src="https://img.shields.io/badge/Download-Latest%20DMG-0A84FF?style=for-the-badge&logo=apple" alt="Download latest DMG" />
  </a>
</p>

## What MinuteWave Does

MinuteWave is a native SwiftUI macOS app focused on fast, private meeting workflows:

- Capture microphone and system audio.
- Produce transcripts with speaker labels (diarization).
- Generate clean meeting summaries.
- Ask follow-up questions in transcript-aware chat.
- Export results as `Markdown`, `TXT`, or `JSON`.

## Key Features

### Recording and Audio Capture

- Native recording flow for macOS.
- Two capture modes:
  - `Microphone only`
  - `Microphone + system audio`
- Built-in elapsed timer and session management.

### Transcription

- Local-first transcription using FluidAudio (`Parakeet TDT v3`) with offline diarization.
- Cloud transcription options:
  - Azure OpenAI
  - OpenAI
- Fallback behavior and provider health/status feedback in-app.

### Summaries and Transcript Chat

- Generate executive summaries from completed transcripts.
- Ask questions against transcript content with retrieval-based context selection.
- Configurable summary prompt template.

### Integrations

MinuteWave can work with:

- **Azure OpenAI**
  - Configurable endpoint, API versions, and deployments for chat/summary/transcription.
- **OpenAI API**
  - Configurable base URL and models for chat/summary/transcription.
- **LM Studio (local server)**
  - Local endpoint for summary + transcript chat.
  - Loaded model selection from running LM Studio instance.

## Security and Privacy

- Local transcription path available for privacy-sensitive workflows.
- API secrets stored in macOS Keychain.
- Optional SQLCipher-backed database encryption with migration support.
- Session data stored locally (SQLite) under app support directories.

## Requirements

- macOS 14+
- Apple Silicon Mac
- 16 GB RAM recommended (and required by onboarding checks for full local workflow)

## Install (DMG)

1. Download: [Latest release](https://github.com/LeonardSEO/MinuteWave/releases/latest)
2. Open `MinuteWave-macOS.dmg`
3. Drag `MinuteWave.app` to `Applications`
4. First launch: right-click app -> **Open**

### Gatekeeper Behavior (Important)

- `spctl --assess` can still return `rejected` when builds are not notarized.
- `codesign --verify` can still be valid while Gatekeeper rejects distribution trust.
- If macOS blocks launch:
  1. Right-click app -> **Open**
  2. Or in terminal: `xattr -dr com.apple.quarantine "/Applications/MinuteWave.app"`

### Code Signing Options

- **Free Apple ID / Personal Team (Xcode):** good for local development on your own Mac; not suitable for public distribution.
- **Paid Apple Developer Program:** required for `Developer ID Application` signing + notarization for clean public install flow.

## Build From Source

```bash
swift build
swift run MinuteWave
```

Run tests:

```bash
swift test
```

Create DMG:

```bash
./scripts/build_dmg.sh release
```

Optional: sign app bundle with a local identity before DMG build:

```bash
security find-identity -v -p codesigning
SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/build_dev_app_bundle.sh release
```

## Architecture (High-Level)

```text
Mic + System Audio
       |
       v
HybridAudioCaptureEngine
       |
       +--> Local FluidAudio (ASR + diarization)
       +--> Azure/OpenAI transcription provider

Transcript + metadata -> SQLite repository
                         |
                         +--> Summary providers (Azure/OpenAI/LM Studio)
                         +--> Transcript chat providers (Azure/OpenAI/LM Studio)
                         +--> ExportService (MD/TXT/JSON)
```

## Versioning and Releases

- Versioning format: `vMAJOR.MINOR.PATCH`.
- App version source: `Sources/AINoteTakerApp/Resources/AppInfo.plist`.
- Release workflow: `.github/workflows/release.yml`.
- On each tag push (example `v0.1.4`), GitHub Actions builds and publishes release assets.
- Sparkle auto-update checks run on app launch and then every 6 hours.

### GitHub Apple Development Signing (Optional)

Set these repository secrets in GitHub:

- `APPLE_DEV_CERT_P12_BASE64` (base64 of exported `.p12` certificate)
- `APPLE_DEV_CERT_PASSWORD` (password used when exporting `.p12`)
- `APPLE_DEV_SIGNING_IDENTITY` (example: `Apple Development: Leonard van Hemert (3RSGDZZR5Z)`)

Create the base64 value locally:

```bash
base64 -i ~/Desktop/apple-development.p12 | pbcopy
```

### Sparkle Auto-Update Signing (Required For Release)

MinuteWave uses Sparkle 2 for in-app updates from GitHub Releases.

- App feed URL: `https://github.com/LeonardSEO/MinuteWave/releases/latest/download/appcast.xml`
- Release assets for updates:
  - `MinuteWave.app.zip`
  - `appcast.xml`

Generate Sparkle keys locally (first time):

```bash
brew install --cask sparkle
SPARKLE_BIN_DIR="$(find "$(brew --prefix)/Caskroom/sparkle" -type d -path "*/bin" | sort | tail -n 1)"
"$SPARKLE_BIN_DIR/generate_keys"
```

Print your public key:

```bash
SPARKLE_BIN_DIR="$(find "$(brew --prefix)/Caskroom/sparkle" -type d -path "*/bin" | sort | tail -n 1)"
"$SPARKLE_BIN_DIR/generate_keys" -p
```

Export your private key (local file):

```bash
SPARKLE_BIN_DIR="$(find "$(brew --prefix)/Caskroom/sparkle" -type d -path "*/bin" | sort | tail -n 1)"
"$SPARKLE_BIN_DIR/generate_keys" -x /tmp/sparkle_private_ed_key.txt
```

Encode the private key for GitHub secret storage:

```bash
base64 -i /tmp/sparkle_private_ed_key.txt | pbcopy
```

Set these repository secrets in GitHub:

- `SPARKLE_PUBLIC_ED_KEY` (plain SUPublicEDKey value)
- `SPARKLE_PRIVATE_ED_KEY_BASE64` (base64 of exported private key file)

Release workflow behavior:

- Fails fast for tag releases if Sparkle secrets are missing.
- Injects `SPARKLE_PUBLIC_ED_KEY` into app `Info.plist` at build time.
- Generates `MinuteWave.app.zip` and `appcast.xml` and publishes them to the tag release.

### Sparkle Troubleshooting

- If `Check for Updates...` is disabled in-app, verify `SUPublicEDKey` is set in the built app.
- If release workflow fails in appcast generation, verify:
  - private key secret is valid base64
  - decoded key matches the configured public key
- If users do not see updates, verify the latest release includes both `MinuteWave.app.zip` and `appcast.xml`.

### Rollback Runbook

If a bad update is published:

1. Create a new hotfix release tag with a fixed build (preferred).
2. If immediate rollback is required, upload a corrected `appcast.xml` to the latest release and point to the last known good `MinuteWave.app.zip`.
3. Publish release notes explaining rollback scope and fixed version.
4. After recovery, rotate Sparkle private key only if key compromise is suspected.

## Current Release

- `v0.1.6`
- DMG asset: `MinuteWave-macOS.dmg`
- Sparkle assets: `MinuteWave.app.zip`, `appcast.xml`

## Documentation

- macOS permissions setup: `docs/XcodePermissionsSetup.md`

## License

MIT License. See [LICENSE](LICENSE).
