# MinuteWave - AI Meeting Notes for macOS

<p align="center">
  <img src="icon-clean.png" alt="MinuteWave logo" width="180" />
</p>

<p align="center">
  Local-first meeting recorder with AI transcription, diarization, summaries, and transcript chat.
</p>

<p align="center">
  <a href="https://github.com/LeonardSEO/AI-note-taker/releases"><img src="https://img.shields.io/github/v/release/LeonardSEO/AI-note-taker?style=for-the-badge" alt="Latest release"></a>
  <a href="https://github.com/LeonardSEO/AI-note-taker/releases"><img src="https://img.shields.io/github/downloads/LeonardSEO/AI-note-taker/total?style=for-the-badge" alt="Downloads"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge" alt="MIT License"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black?style=for-the-badge&logo=apple" alt="macOS 14+">
</p>

<p align="center">
  <a href="https://github.com/LeonardSEO/AI-note-taker/releases/latest/download/MinuteWave-macOS-unsigned.dmg">
    <img src="https://img.shields.io/badge/Download-Latest%20DMG-0A84FF?style=for-the-badge&logo=apple" alt="Download DMG" />
  </a>
</p>

## Why MinuteWave

MinuteWave is a native SwiftUI app for Apple Silicon Macs that captures microphone + system audio, creates transcripts with speaker separation, and helps you turn long meetings into clear notes and actions.

## Highlights

- Native macOS app built with SwiftUI.
- Local-first transcription with FluidAudio (Parakeet TDT v3 + offline diarization).
- Azure/OpenAI support for cloud transcription and AI responses.
- LM Studio local endpoint support for summary and transcript chat.
- Transcript-aware chat with chunk retrieval.
- Export to Markdown, TXT, and JSON.
- Privacy mode with SQLCipher migration support.

## Quick Start

### 1. Download

Download the latest DMG from the releases page:

- [Latest release](https://github.com/LeonardSEO/AI-note-taker/releases/latest)
- [Direct DMG download](https://github.com/LeonardSEO/AI-note-taker/releases/latest/download/MinuteWave-macOS-unsigned.dmg)

### 2. Install

1. Open `MinuteWave-macOS-unsigned.dmg`
2. Drag `MinuteWave.app` to `Applications`
3. On first launch, right-click the app and choose **Open** (unsigned build)

## Build From Source

```bash
swift build
swift run MinuteWave
```

Run tests:

```bash
swift test
```

Build an unsigned release DMG:

```bash
./scripts/build_unsigned_dmg.sh release
```

## Versioning and Releases

MinuteWave follows semantic version tags:

- `vMAJOR.MINOR.PATCH` (example: `v0.1.0`)

Release source of truth:

- App version is stored in `Sources/AINoteTakerApp/Resources/AppInfo.plist` (`CFBundleShortVersionString`)
- Git tags and GitHub Releases use the same version prefix (`v`)

A GitHub Actions workflow is included at `.github/workflows/release.yml`:

- Trigger on version tags like `v0.1.0`
- Build the macOS DMG
- Publish a GitHub Release with downloadable artifacts

## Security and Privacy

- Local provider can run fully in-process.
- API keys are stored in Keychain.
- Optional database encryption with SQLCipher migration.

## Documentation

- macOS permission setup: `docs/XcodePermissionsSetup.md`

## License

MIT License - see [LICENSE](LICENSE).
