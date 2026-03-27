<!-- Managed by agent: keep sections and order; edit content, not structure. Last updated: 2026-03-27 -->

# AGENTS.md — Tests/AINoteTakerAppTests

## Overview
Swift Testing coverage for storage, migrations, policy validation, localization, parsing, and selected view-model helpers. The suite currently lives in one file and uses helper fixtures near the top of that file.

## Key Files
| File | Purpose |
|------|---------|
| `AINoteTakerAppTests.swift` | all current tests, fixture builders, `StubURLProtocol`, migration helpers, localization key extraction |

## Golden Samples (follow these patterns)
| Pattern | Reference |
|---------|-----------|
| Repository roundtrip test with temp database | `defaultSettingsRoundTrip` |
| URLSession stubbing for network-facing services | `StubURLProtocol` and `gitHubUpdateServiceFallsBackForUntrustedPayloadURL` |
| Migration fixture seeding/assertion helpers | `seedMigrationFixture` and `assertMigrationFixture` |
| Policy validation tests | `openAIEndpointPolicyRequiresHTTPS` and `trustedReleaseURLPolicyRestrictsHostAndPath` |
| Localization coverage guard | `localizationKeyCoverage` |

## Setup & environment
- Test framework: Swift Testing (`import Testing`)
- Main command: `swift test`
- Single-test command: `swift test --filter <test-name>`
- Status on 2026-03-27: `swift test` currently fails before reaching app tests because `FluidAudio` does not compile under the active toolchain

## Code style & conventions
- Prefer `@Test("descriptive name")` with focused expectations.
- Use `#expect` and `#require` consistently; avoid XCTest-style patterns unless the file already needs them.
- Keep helpers private and near the top of the file when they serve multiple tests.
- Use temporary directories/databases and clean them up with `defer`.
- Stub network interactions with `StubURLProtocol` instead of hitting live services.

## Security & safety
- Do not add real API keys, signing identities, or user data to fixtures.
- Prefer deterministic fixtures over network-dependent or clock-sensitive tests.
- Preserve coverage around endpoint validation, release URL trust, encryption defaults, and migration safety.

## PR/commit checklist
- [ ] Added or updated tests for any changed repository, policy, or settings behavior
- [ ] New fixtures clean up temp files
- [ ] Network-related tests use stubs, not live endpoints
- [ ] Localization-related changes keep the coverage test meaningful
- [ ] Validation claims mention the current `FluidAudio` compile blocker when relevant

## Patterns to Follow
- If production code adds a new policy or migration branch, add one success path and one rejection/failure-path test.
- If a settings model changes, add backward-compatibility decoding coverage where needed.
- If storage schema changes, roundtrip through `SQLiteRepository` instead of asserting only on in-memory models.

## When stuck
- Start from an adjacent test in `AINoteTakerAppTests.swift` and match its fixture style.
- Use the root and source-scoped `AGENTS.md` files for architectural context before writing a new test seam.
