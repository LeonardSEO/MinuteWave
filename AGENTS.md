<!-- FOR AI AGENTS - Human readability is a side effect, not a goal -->
<!-- Managed by agent: keep sections and order; edit content, not structure -->
<!-- Last updated: 2026-03-27 | Last verified: 2026-03-27 -->

# AGENTS.md

**Precedence:** the **closest `AGENTS.md`** to the files you're changing wins. Root holds repo-wide defaults only.

## Commands (verified on 2026-03-27; current HEAD is red)
> Source: `Package.swift`, `scripts/`, `.github/workflows/release.yml`

| Task | Command | ~Time |
|------|---------|-------|
| Typecheck | `swift build` | ~2-6m |
| Lint | `None configured` | n/a |
| Format | `None configured` | n/a |
| Test (single) | `swift test --filter localizationKeyCoverage` | ~30-90s after green build |
| Test (all) | `swift test` | ~3-8m |
| Build app bundle | `./scripts/build_dev_app_bundle.sh debug` | ~4-10m |
| Build DMG | `./scripts/build_dmg.sh release` | ~5-15m |

- `swift build`, `swift test`, and `./scripts/build_dev_app_bundle.sh debug` were rerun on 2026-03-27.
- All three currently fail while compiling `FluidAudio 0.12.1`, specifically `.build/checkouts/FluidAudio/Sources/FluidAudio/ASR/Streaming/StreamingAsrManager.swift`, with Swift concurrency `SendingRisksDataRace` diagnostics.
- Do not claim local app code is green until that dependency/toolchain issue is resolved.

## Workflow
1. Read this file, then load the nearest scoped `AGENTS.md` before editing.
2. Prefer the smallest relevant verification step first; escalate to full `swift test` only when shared code changes.
3. For macOS permission work, test with a real app bundle, not `swift run`, because TCC identity depends on the bundle.
4. Show concrete command output before claiming the repo is fixed.

## File Map
```text
.github/workflows/      -> release automation for tagged DMG builds
Sources/AINoteTakerApp/ -> app code: App, Features, Services, Data, Utilities, UI
Tests/AINoteTakerAppTests/ -> Swift Testing coverage for storage, security, parsing, localization
scripts/                -> local app bundle, DMG, and TCC reset helpers
docs/                   -> operator docs for permission/TCC behavior
dist/                   -> generated release artifacts
```

## Golden Samples (follow these patterns)
| For | Reference | Key patterns |
|-----|-----------|--------------|
| Dependency wiring and startup policy | `Sources/AINoteTakerApp/App/AppContainer.swift` | central construction, filesystem bootstrap, encryption migration decisions |
| Shared app state and side effects | `Sources/AINoteTakerApp/App/AppViewModel.swift` | `@MainActor` state owner, repository-driven persistence, provider orchestration |
| Main SwiftUI screen composition | `Sources/AINoteTakerApp/Features/Main/MainWorkspaceView.swift` | split panels, localized strings, no direct storage/network access in view |
| Secure local persistence | `Sources/AINoteTakerApp/Data/SQLiteRepository.swift` | serialized DB queue, explicit SQL, Codable payloads |
| Secret handling | `Sources/AINoteTakerApp/Utilities/KeychainStore.swift` | Keychain-only secrets, legacy migration, no API-key caching |
| Regression tests | `Tests/AINoteTakerAppTests/AINoteTakerAppTests.swift` | `@Test`, `#expect`, temp fixtures, URLProtocol stubs |

## Utilities (check before creating new)
| Need | Use | Location |
|------|-----|----------|
| App support paths | `AppPaths` | `Sources/AINoteTakerApp/Utilities/AppPaths.swift` |
| Secret storage | `KeychainStore` | `Sources/AINoteTakerApp/Utilities/KeychainStore.swift` |
| HTTP retries | `HTTPRetryPolicy` | `Sources/AINoteTakerApp/Utilities/HTTPRetryPolicy.swift` |
| Permission checks / settings deep links | `Permissions` | `Sources/AINoteTakerApp/Utilities/Permissions.swift` |
| OpenAI endpoint validation | `OpenAIEndpointPolicy` | `Sources/AINoteTakerApp/Utilities/OpenAIEndpointPolicy.swift` |
| Release URL validation | `TrustedReleaseURLPolicy` | `Sources/AINoteTakerApp/Utilities/TrustedReleaseURLPolicy.swift` |
| Azure endpoint paste parsing | `AzureEndpointPasteParser` | `Sources/AINoteTakerApp/Utilities/AzureEndpointPasteParser.swift` |
| Exporting session output | `ExportService` | `Sources/AINoteTakerApp/Services/ExportService.swift` |

## Heuristics (quick decisions)
| When | Do |
|------|-----|
| Editing UI copy | Use `L10n.tr(...)` and update both `en.lproj` and `nl.lproj` |
| Adding settings | Wire through `AppSettings`, persistence in `SQLiteRepository`, and UI in onboarding/settings |
| Changing transcript/session data | Update `SessionRepository` contract and add or extend storage tests |
| Touching permissions or capture flow | Preserve microphone-only fallback and real-bundle TCC behavior |
| Touching external URLs | Validate hosts/paths with the existing policy utilities before shipping |
| Handling secrets | Store only in Keychain, never in defaults, plist, logs, or test fixtures |
| Unsure about a pattern | Copy from the Golden Samples above instead of inventing a new layer |

## Repository Settings
- Default branch: `main`
- Product name: `MinuteWave`
- Bundle identifier: `com.vepando.minutewave`
- Platform target: macOS 14+, Apple Silicon-first workflow
- Package manager / build system: Swift Package Manager
- No repo-level formatter, linter, or pre-commit hook is configured today

## CI Rules
- Release workflow lives at `.github/workflows/release.yml`
- Release job runs on `macos-latest` for git tags matching `v*.*.*`
- CI installs `create-dmg` and `sqlcipher` with Homebrew before packaging
- CI signs with Apple Development credentials when secrets exist; otherwise it falls back to ad-hoc signing
- Release artifacts are `dist/MinuteWave-macOS.dmg` and `dist/MinuteWave-macOS.dmg.sha256`

## Key Decisions
- Local-first meeting capture is the default posture; cloud providers are optional.
- App state is centralized in `AppViewModel`; views should not own persistence or provider logic.
- Sessions live in local SQLite; secrets live in Keychain; optional SQLCipher migration is built in.
- Update checks are limited to trusted GitHub release URLs for the configured repo.
- Permission-sensitive testing should happen via `.app` bundles built by `scripts/build_dev_app_bundle.sh`.

## Boundaries

### Always Do
- Add or update tests for new storage, parsing, security, and state transitions.
- Keep user-facing strings localized through `L10n`.
- Reuse existing policies and utilities before adding new helpers or abstractions.
- Call out the current `FluidAudio` build failure when relevant to validation claims.

### Ask First
- Adding or replacing Swift package dependencies.
- Changing release/signing behavior in `.github/workflows/release.yml` or `scripts/build_dmg.sh`.
- Altering schema/migration behavior that can affect existing local user data.
- Disabling endpoint validation, release URL validation, or encryption safeguards.

### Never Do
- Commit API keys, database keys, signing material, or sample secrets.
- Bypass Keychain for real secrets or persist them in app settings.
- Hardcode untranslated UI strings in SwiftUI views.
- Claim `swift build` or `swift test` passed until the dependency compile issue is actually fixed.

## Codebase State
- Current blocker: `FluidAudio 0.12.1` fails to compile under the active toolchain due to Swift concurrency diagnostics in `StreamingAsrManager.swift`.
- Tests are concentrated in a single `AINoteTakerAppTests.swift` file; keep new tests grouped but readable until the suite is split.
- The repo uses the package name `MinuteWave` while the source target remains `AINoteTakerApp`; do not rename casually.
- `scripts/build_unsigned_dmg.sh` is deprecated; prefer `scripts/build_dmg.sh`.

## Terminology
| Term | Means |
|------|-------|
| Session | one recording/transcription workspace persisted in SQLite |
| Segment | timestamped transcript chunk, optionally with speaker label |
| Summary | structured markdown-derived meeting recap stored per session version |
| Local FluidAudio | on-device transcription path with offline diarization/model prep |
| Cloud provider | Azure OpenAI, OpenAI, or LM Studio for summary/chat, and Azure/OpenAI for transcription |
| TCC | macOS privacy permission system for microphone and screen/system audio capture |

## Scoped AGENTS.md
- `Sources/AINoteTakerApp/AGENTS.md` for app architecture, UI, services, storage, and security rules
- `Tests/AINoteTakerAppTests/AGENTS.md` for Swift Testing patterns and fixture conventions

## When instructions conflict
The nearest `AGENTS.md` wins. Explicit user prompts override files.
