<h1 align="center">
  <br>
  <img src="icon-clean.png" alt="MinuteWave logo" width="140" />
  <br>
  MinuteWave
  <br>
</h1>

<p align="center">
  <strong>Local-first AI meeting copilot for macOS.</strong>
</p>

<p align="center">
  Capture meeting audio, generate high-quality transcripts with speaker labels, create structured summaries, and chat with transcript-grounded citations.
</p>

<p align="center">
  <a href="https://github.com/LeonardSEO/MinuteWave/actions/workflows/release.yml"><img src="https://img.shields.io/github/actions/workflow/status/LeonardSEO/MinuteWave/release.yml?style=for-the-badge&label=Release" alt="Release workflow"></a>
  <a href="https://github.com/LeonardSEO/MinuteWave/releases"><img src="https://img.shields.io/github/v/release/LeonardSEO/MinuteWave?style=for-the-badge" alt="Latest release"></a>
  <a href="https://github.com/LeonardSEO/MinuteWave/releases"><img src="https://img.shields.io/github/downloads/LeonardSEO/MinuteWave/total?style=for-the-badge" alt="Downloads"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge" alt="MIT License"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black?style=for-the-badge&logo=apple" alt="macOS 14+">
</p>

<p align="center">
  <a href="https://github.com/LeonardSEO/MinuteWave/releases/latest/download/MinuteWave-macOS.dmg"><strong>Download latest DMG</strong></a>
  ·
  <a href="docs/XcodePermissionsSetup.md"><strong>Permissions setup guide</strong></a>
</p>

## Why MinuteWave

MinuteWave is built for people who want native macOS meeting notes without a browser-first workflow:

- Local transcription path with FluidAudio (Parakeet v3 + offline diarization).
- Cloud transcription options with Azure OpenAI or OpenAI.
- Transcript-aware AI chat and summary generation.
- Session persistence, export, and optional database encryption.
- Native SwiftUI UI with onboarding, settings, and update checks.

## Feature Overview

| Area | What you get |
| --- | --- |
| Audio capture | `Microphone only` or `Microphone + system audio` capture modes |
| Transcription | Local FluidAudio, Azure OpenAI Whisper, or OpenAI Whisper |
| Speaker labels | Offline diarization in local FluidAudio mode |
| Summary | Structured markdown summary generation from transcript content |
| Transcript chat | Q&A with lexical retrieval and timestamp citations |
| Export | `Markdown`, `TXT`, and `JSON` export per session |
| Storage | Local SQLite session store + Keychain-backed secrets |
| Security | Optional SQLCipher encryption mode with migration support |
| UX | EN/NL app localization, onboarding wizard, update checker |

### Provider Matrix

| Capability | Local FluidAudio | Azure OpenAI | OpenAI | LM Studio |
| --- | --- | --- | --- | --- |
| Transcription | Yes | Yes | Yes | No |
| Summary | No | Yes | Yes | Yes |
| Transcript chat | No | Yes | Yes | Yes |
| API key required | No | Yes | Yes | Optional |

## Architecture

```mermaid
flowchart LR
  A["Microphone"] --> B["HybridAudioCaptureEngine"]
  C["System audio (optional)"] --> B
  B --> D["Transcription provider"]
  D --> E["SQLite session repository"]
  E --> F["Summary provider"]
  E --> G["Transcript chat + citations"]
  E --> H["Export service (MD/TXT/JSON)"]

  subgraph Providers
    D1["Local FluidAudio"]
    D2["Azure OpenAI"]
    D3["OpenAI"]
  end

  subgraph Summary/Chat
    S1["Azure OpenAI"]
    S2["OpenAI"]
    S3["LM Studio"]
  end

  D --- D1
  D --- D2
  D --- D3
  F --- S1
  F --- S2
  F --- S3
  G --- S1
  G --- S2
  G --- S3
```

## System Requirements

- macOS `14+`
- Apple Silicon Mac
- `16 GB RAM` minimum (enforced by onboarding checks)
- Internet connection for cloud providers and first local model download

## Installation (DMG)

1. Download from [latest release](https://github.com/LeonardSEO/MinuteWave/releases/latest).
2. Open `MinuteWave-macOS.dmg`.
3. Drag `MinuteWave.app` to `Applications`.
4. Start with right-click -> `Open` on first run.

> [!IMPORTANT]
> If Gatekeeper blocks launch, use one of these options:
> 1. `System Settings -> Privacy & Security -> Open Anyway`
> 2. `xattr -dr com.apple.quarantine "/Applications/MinuteWave.app"`

## Quick Start

1. Complete onboarding permissions (`Microphone`, and optionally `Screen Recording` for system audio capture).
2. Choose your transcription provider (`Local (FluidAudio)` for local-first workflow, or `Azure`/`OpenAI` for cloud transcription).
3. (Optional) Configure summary/chat provider (`Azure`, `OpenAI`, or `LM Studio`).
4. Create a session, start recording, stop recording.
5. Review transcript, generate summary, ask follow-up questions, export results.

## Privacy & Security

- Session data is stored locally in `~/Library/Application Support/MinuteWave`.
- API keys are stored in macOS Keychain.
- Database encryption can be enabled in settings when SQLCipher runtime is available.
- Encryption migrations (plaintext <-> SQLCipher) are built in.
- Local FluidAudio mode keeps inference on-device after model preparation.

## Build From Source

### Prerequisites

- Xcode (latest stable)
- Swift 6 toolchain
- Homebrew packages:

```bash
brew install sqlcipher create-dmg
```

### Build and run

```bash
swift build
swift test
swift run MinuteWave
```

For reliable macOS permission prompts, run as a real app bundle:

```bash
./scripts/build_dev_app_bundle.sh debug
open ".build/AppBundle/MinuteWave.app"
```

### Build DMG

```bash
./scripts/build_dmg.sh release
```

Optional signing:

```bash
security find-identity -v -p codesigning
SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/build_dev_app_bundle.sh release
```

## Release and CI

- Release workflow: `.github/workflows/release.yml`
- Tag format: `vMAJOR.MINOR.PATCH`
- Release artifacts: `MinuteWave-macOS.dmg`, `MinuteWave-macOS.dmg.sha256`

## Troubleshooting

- Permission issues: see [`docs/XcodePermissionsSetup.md`](docs/XcodePermissionsSetup.md)
- Reset TCC permissions:

```bash
./scripts/reset_tcc_permissions.sh
```

- LM Studio model not detected: refresh status in Settings -> `AI` tab and ensure at least one model is loaded.

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=LeonardSEO/MinuteWave&type=date&legend=top-left)](https://www.star-history.com/#LeonardSEO/MinuteWave&type=date&legend=top-left)

## License

MIT License. See [LICENSE](LICENSE).
