<!-- Managed by agent: keep sections and order; edit content, not structure. Last updated: 2026-03-27 -->

# AGENTS.md — Sources/AINoteTakerApp

## Overview
macOS SwiftUI app code for MinuteWave. `AppViewModel` is the state hub, `AppContainer` wires concrete dependencies, `SQLiteRepository` owns persistence, and `Services/` contains provider integrations.

## Key Files
| File | Purpose |
|------|---------|
| `App/AINoteTakerApp.swift` | app entry point, commands, and environment wiring |
| `App/AppContainer.swift` | dependency construction, app support bootstrapping, encryption mode resolution |
| `App/AppViewModel.swift` | main state machine for onboarding, recording, chat, summaries, and settings |
| `Data/SQLiteRepository.swift` | local storage implementation for sessions, segments, summaries, chat, settings |
| `Features/Main/MainWorkspaceView.swift` | primary workspace UI |
| `Features/Onboarding/OnboardingWizardView.swift` | first-run requirements and provider setup |
| `Features/Settings/SettingsView.swift` | persistent settings editor and update UI |
| `Utilities/KeychainStore.swift` | secret storage and legacy migration |

## Golden Samples (follow these patterns)
| Pattern | Reference |
|---------|-----------|
| Dependency injection without view-level service creation | `App/AppContainer.swift` |
| `@MainActor` orchestration with async side effects | `App/AppViewModel.swift` |
| SwiftUI screen composition with localized strings | `Features/Main/MainWorkspaceView.swift` |
| Security-focused URL validation | `Services/GitHubUpdateService.swift` and `Utilities/OpenAIEndpointPolicy.swift` |
| Storage implementation with explicit SQL and queue isolation | `Data/SQLiteRepository.swift` |

## Setup & environment
- Build system: SwiftPM (`Package.swift`)
- Target platform: macOS 14+
- External dependency: `FluidAudio`
- SQLCipher is linked dynamically; release/build scripts expect `sqlcipher` to be installed via Homebrew
- For permission-sensitive testing, prefer `./scripts/build_dev_app_bundle.sh debug` and launch the resulting `.app`

## Build & tests
- Typecheck: `swift build`
- Test: `swift test`
- App bundle: `./scripts/build_dev_app_bundle.sh debug`
- DMG: `./scripts/build_dmg.sh release`
- Status on 2026-03-27: the commands above are the correct entry points, but current HEAD fails while compiling `FluidAudio`

## Code style & conventions
- Keep `AppViewModel` as the orchestrator; do not move persistence or provider side effects into SwiftUI views.
- Keep views declarative and localized with `L10n.tr(...)`.
- Reuse domain models and protocols from `Domain/` instead of introducing duplicate DTOs.
- Prefer existing utilities for permissions, path resolution, retries, hashing, endpoint validation, and logging.
- Keep secrets in `KeychainStore`; settings and other non-secret state belong in repository-backed `AppSettings`.
- Match the existing style: small helper types, focused extensions, and no gratuitous abstraction layers.

## Security & safety
- Preserve `TrustedReleaseURLPolicy`, `OpenAIEndpointPolicy`, `ModelRegistryPolicy`, and related guards when changing network behavior.
- Keep localhost-only exceptions limited to the existing ATS allowances for LM Studio.
- Never log API keys, database keys, or transcript content unless the file already does so deliberately and safely.
- Any change affecting local database encryption must preserve plaintext <-> SQLCipher migration behavior.

## PR/commit checklist
- [ ] Smallest relevant command rerun and output captured
- [ ] Any changed UI copy added to both `Resources/en.lproj/Localizable.strings` and `Resources/nl.lproj/Localizable.strings`
- [ ] Storage/protocol changes covered by tests
- [ ] Permissions, TCC, or update flows manually reasoned through against existing safeguards
- [ ] No secrets persisted outside Keychain

## Patterns to Follow
- View -> `AppViewModel` -> protocol/service/repository is the default direction.
- Onboarding and Settings should stay in sync for provider configuration fields and validation.
- Local-first workflows should degrade safely to microphone-only or offline-ready states when permissions/services are unavailable.

## When stuck
- Check root `AGENTS.md` first for repo-wide constraints and the current build blocker.
- Use `AppViewModel`, `SQLiteRepository`, and `MainWorkspaceView` as the first references before inventing new patterns.
- Read `docs/XcodePermissionsSetup.md` before changing permission or packaging behavior.
