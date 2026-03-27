# MinuteWave Plan: First TestFlight, Then Public Launch

## Summary
The first milestone is a **ship-ready TestFlight build on Maciej’s Apple Developer account**. Everything required to reach that milestone gets priority: unblocking builds, establishing the Xcode/App Store foundation, fixing screen recording, fixing LM Studio streaming, polishing onboarding, redesigning transcript UX, adding session deletion, cleaning up localization, and beta QA. The landing page comes **after** TestFlight.

Split of responsibilities: **Leonard** owns AI/backend/product logic, **Maciej** owns macOS distribution/signing/UI polish/release track, and **both** own roadmap decisions, bug triage, and go/no-go decisions.

## Key Implementation Decisions
- A **native Xcode project** will be introduced for archiving, signing, entitlements, and App Store Connect uploads. `Package.swift` remains for development/reference, but Xcode becomes the release source of truth.
- The first distribution route is **TestFlight/App Store**, not the current DMG flow. Developer ID/notarization for direct distribution stays post-beta.
- Transcript UX will be rebuilt around **post-recording tabs**: `Summary`, `Chat`, `Transcript`. During recording/finalizing, the transcript is not shown live; after completion, `Transcript` becomes available in its own tab.
- LM Studio streaming will be fixed first via the **official LM Studio OpenAI-compatible streaming route** (`/v1/chat/completions` with `stream: true`) because it fits the current provider architecture best. Native `/api/v1/chat` remains a fallback/phase-2 option.
- Onboarding becomes a **two-layer UX**: essentials first, advanced fields only when relevant. Provider-specific details that are not needed for first run move to Settings/Advanced.
- `SessionRepository` and the related app flow will be extended for **session deletion**. Audio saving/export is planned for post-TestFlight unless beta-blocker triage makes it critical.
- Structured summaries become real **structured output** instead of only `executiveSummary` with empty arrays.

## Phases and Ownership

### Phase 0: Collaboration and Release Prerequisites
- Leonard: create a GitHub milestone board with labels `beta-blocker`, `release-foundation`, `ux`, `ai`, `distribution`, `post-beta`.
- Maciej: create the App Store Connect app, reserve the bundle ID under his team, and confirm whether `com.vepando.minutewave` can remain unchanged.
- Leonard: write a short collaboration memo covering 50/50 revenue split, IP ownership, repo ownership, and exit/change-of-scope terms.
- Maciej: review and confirm that memo before subscriptions/App Store revenue go live.
- Both: agree on branch/PR rules, with Maciej owning release/distribution PRs, Leonard owning AI/provider PRs, and shared review for cross-cutting changes.

### Phase 1: Unblock Builds and Establish Shipping Foundation
- Leonard: resolve the current **FluidAudio/Xcode toolchain blocker** or pin to a working dependency/toolchain combination so the project builds and tests again.
- Maciej: create a **native Xcode macOS app target** with shared schemes, archiveable configuration, signing, capabilities, and a real entitlements file.
- Maciej: add the minimum App Store/TestFlight capabilities: App Sandbox, outgoing network client, microphone, user-selected file access where needed, plus correct Info.plist/privacy fields.
- Maciej: add `PrivacyInfo.xcprivacy` and audit transitive SDK/privacy manifest status for the archive.
- Maciej: replace the current script-only signing flow as the primary release route with Xcode archive/export; DMG scripts remain legacy/dev tooling.
- Both: prepare a release checklist for internal TestFlight upload, install, first launch, permissions, recording, summary, chat, and export.

### Phase 2: Beta-Blocking Product and Technical Work
- Maciej: reproduce and fix the **screen recording/system audio bug** in a real bundle/Xcode/TestFlight context, including TCC restart UX and sandbox validation.
- Leonard: support that with engine-level fixes in permission-state logic and capture fallback so “permissions are enabled but the app thinks they are not” stops happening.
- Leonard: implement **LM Studio streaming** for chat/summary output, with better diagnostics, model-selection robustness, and retry/status handling.
- Maciej: improve the LM Studio UI/status surface, including loading/error/empty states.
- Maciej: rebuild **onboarding** into a faster, less technical flow that only shows relevant checks and moves advanced fields out of the default path.
- Leonard: simplify the onboarding validation logic and make permission/provider checks lazy and less fragile.
- Maciej: build the new **tab-based post-recording workspace** for `Summary`, `Chat`, and `Transcript`.
- Leonard: ensure retrieval/chat/summaries still run from stored transcript data while transcript is hidden during recording.
- Leonard: implement **session deletion** end-to-end in repository/domain/state.
- Maciej: add delete UI, confirmation flow, and empty-state UX.
- Leonard: make **structured summaries** truly structured with populated `decisions`, `actionItems`, `openQuestions`, `followUps`, and `risks`.
- Maciej: update summary rendering so that structure is visible and scannable in the UI.
- Maciej: clean up **English UI flows with Dutch leaks** in onboarding/settings/main flows.
- Both: run a broad bug sweep under `other bugs`; everything marked `beta-blocker` must be closed before the first TestFlight.

### Phase 3: Targeted Refactor and Beta Hardening
- Leonard: split the God `AppViewModel` **surgically**, not as a wholesale rewrite, by extracting recording/transcription/chat/summary logic into focused coordinators/services.
- Maciej: split the associated presentation state for onboarding/workspace/settings into smaller view-facing models or extensions.
- Leonard: add tests for session deletion, structured summary parsing/mapping, LM Studio streaming parsing, and permission-state regressions.
- Maciej: add UI smoke tests/manual test scripts for onboarding, permission flow, transcript-tab UX, and settings.
- Both: run internal TestFlight for themselves plus a small trusted cohort; feedback is labeled in GitHub and translated into fixes.

### Phase 4: Post-TestFlight to Public Launch
- Maciej: build the **landing page** after the first TestFlight, at MakLock quality, with clear positioning, screenshots, privacy angle, and CTA.
- Leonard: provide copy/input for the AI value proposition, local-first messaging, and comparison copy.
- Maciej: prepare App Store metadata, screenshots, privacy policy URL, product page, and release notes.
- Leonard: work out monetization design for freemium + Pro gating; Maciej then maps that to StoreKit/App Store Connect.
- Both: decide after beta whether **audio saving/export** must land before App Store launch or can move to v1.1.
- Maciej: if direct download remains in scope, add Developer ID + hardened runtime + notarization/stapling to the DMG track after beta.

## Leonard Status Snapshot (March 27, 2026)

### Done
- [x] Resolve the FluidAudio/Xcode toolchain blocker in a durable, repo-tracked way.
Current state: the local `.build/checkouts/FluidAudio` workaround has been replaced by a vendored dependency under `Vendor/FluidAudio`, documented with the applied Swift concurrency compatibility patch.
- [x] Support the screen recording/system audio bug with engine-level permission-state and capture fallback fixes.
Current state: backend permission-state handling, denial classification, guidance messaging, and mic-only fallback behavior were tightened. Final real-bundle/TestFlight validation still depends on Maciej’s Xcode/sandbox work.
- [x] Implement LM Studio streaming for chat output, including streaming parsing and incremental assistant updates.
- [x] Simplify onboarding validation logic and make permission/provider checks lazier and less fragile.
Current state: onboarding now treats microphone permission as required, while screen recording becomes a deferred runtime concern instead of a first-run hard blocker.
- [x] Ensure retrieval/chat/summaries continue to work from stored transcript data.
- [x] Implement session deletion end-to-end in repository/domain/state.
- [x] Implement structured summaries with populated `decisions`, `actionItems`, `openQuestions`, `followUps`, and `risks`.
- [x] Split the God `AppViewModel` surgically by extracting Leonard-owned recording/chat/summary orchestration into focused services.
Current state: recording flow and assistant flow now live in dedicated services. The view model is still sizable, but the Leonard-owned business logic seams have been split out.
- [x] Add tests for session deletion, structured summary parsing/mapping, LM Studio streaming parsing, and permission-state regression coverage.
- [x] Write the collaboration memo for revenue split, IP ownership, repo ownership, and exit/change-of-scope terms.
- [x] Provide copy/input for the AI value proposition, local-first messaging, and comparison copy.
- [x] Work out the monetization design for freemium + Pro gating.

### Not Done Yet
- [ ] Create the GitHub milestone board with labels `beta-blocker`, `release-foundation`, `ux`, `ai`, `distribution`, `post-beta`.

### Verification Notes
- [x] `swift test` passes after the current Leonard-owned changes.
- [ ] The `sqlcipher` linker warning is still present and should be cleaned up later, even though it is not currently blocking local builds or tests.

## Test and Acceptance Criteria
- Build/ship gate: the project archives from Xcode and can be uploaded as a macOS TestFlight build.
- Permission gate: mic + system audio work in a real app bundle; screen recording false-negatives are gone; recovery after a permission change is clear.
- LM Studio gate: model detection works, streamed output arrives incrementally, and failures are understandable in UI/logs.
- UX gate: during recording/finalizing no transcript is shown; after completion the transcript is available in its own tab; onboarding feels shorter and only shows advanced steps when needed.
- Product gate: sessions can be deleted; summaries contain real structured sections; English smoke flows no longer leak Dutch strings.
- QA gate: the internal TestFlight smoke test covers onboarding, record/pause/stop, summary, chat, export, session deletion, settings, LM Studio, and screen/audio capture.
- Launch gate: only after beta feedback review do we decide on App Store submission, monetization rollout, and landing-page publication.

## Assumptions and Defaults
- The first milestone is **TestFlight**, not direct App Store submission.
- The plan includes collaboration/admin work, not only engineering work.
- The landing page is **post-TestFlight**.
- The bundle ID should stay `com.vepando.minutewave` if Maciej’s team can use it; if not, Maciej chooses the new ID and Leonard updates the app-side references.
- Audio saving/export is **not a TestFlight blocker**; session deletion and structured summaries are.
- DMG/notarization is **post-beta** unless you decide to support testers outside TestFlight as well.

## References
- Apple TestFlight overview: https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/
- Apple App Sandbox overview: https://developer.apple.com/documentation/security/app-sandbox
- Apple configuring macOS App Sandbox: https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox/
- Apple app sandbox upload info / temporary exceptions: https://developer.apple.com/help/app-store-connect/reference/app-uploads/app-sandbox-information/
- Apple app privacy details: https://developer.apple.com/app-store/app-privacy-details/
- Apple app privacy configuration / privacy manifest: https://developer.apple.com/documentation/bundleresources/app-privacy-configuration
- Apple TN3181 invalid privacy manifest: https://developer.apple.com/documentation/technotes/tn3181-debugging-invalid-privacy-manifest
- Apple third-party SDK requirements: https://developer.apple.com/support/third-party-SDK-requirements/
- LM Studio API overview: https://lmstudio.ai/docs/developer/rest
- LM Studio chat endpoint: https://lmstudio.ai/docs/developer/rest/chat
- LM Studio streaming events: https://lmstudio.ai/docs/developer/rest/streaming-events
- LM Studio OpenAI-compatible chat completions: https://lmstudio.ai/docs/developer/openai-compat/chat-completions
