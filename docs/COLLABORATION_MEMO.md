# MinuteWave Collaboration Memo

Date: March 27, 2026

This memo is a working agreement between Leonard and Maciej for the development, distribution, and commercialization of MinuteWave. It is meant to remove ambiguity while the product is being built and prepared for TestFlight and public launch. It is not intended to replace a formal legal agreement if one is needed later.

## 1. Parties

- Leonard: product owner of the existing MinuteWave codebase and GitHub repository
- Maciej: collaborator focused on macOS distribution, App Store readiness, and launch execution

## 2. Project Scope

MinuteWave is a macOS meeting note taker focused on transcription, summaries, and local-first privacy.

The current milestones are:

- first milestone: internal TestFlight build
- second milestone: public launch

## 3. Role Split

Leonard owns:

- AI/backend/product logic
- transcription providers
- summarization and LLM integration
- local model/runtime behavior
- product logic for pricing and feature gating

Maciej owns:

- Xcode project setup
- code signing
- entitlements and sandboxing
- TestFlight/App Store setup
- distribution UX polish
- landing page and launch-facing assets

Shared ownership:

- roadmap decisions
- feature prioritization
- QA and release go/no-go
- strategic product direction

## 4. Repository and Code Ownership

- The main GitHub repository remains under Leonard's GitHub unless both parties agree otherwise in writing.
- Each party retains authorship of the code they contribute.
- Contributions made to MinuteWave are intended for use in MinuteWave and its distribution.
- Neither party should remove the other's authorship, access, or major work without discussion.
- If the project later moves into a company structure, ownership terms should be rewritten formally.

## 5. Revenue Split

- Net revenue from MinuteWave will be split 50/50 between Leonard and Maciej.
- "Net revenue" means money actually received after Apple fees, taxes, refunds, chargebacks, and required platform costs directly tied to sales.
- If extra ongoing infrastructure costs become material, both parties will agree in writing whether those are deducted before split.

## 6. Publishing and Developer Account

- MinuteWave will initially be published under Maciej's Apple Developer account because he has the account needed for App Store/TestFlight distribution.
- Publishing under Maciej's account does not by itself transfer product ownership to Maciej.
- App Store Connect access, payout visibility, and reporting should be transparent to both parties.

## 7. Decision-Making

- Leonard has final say on AI/product logic decisions.
- Maciej has final say on Apple distribution implementation details and release mechanics.
- Major product, pricing, branding, or scope changes should be agreed by both parties.
- If there is disagreement on a major decision, public launch should pause until resolved.

## 8. Contribution Expectations

- Both parties are expected to communicate clearly about delays, blockers, and scope changes.
- Silence for a short busy period is acceptable.
- If one party becomes unavailable for an extended period, the other may continue operational work, but not change the commercial split unilaterally.

## 9. If One Person Stops Contributing

- If one party pauses temporarily, the collaboration remains in place unless explicitly ended.
- If one party fully exits, both parties should agree in writing on one of:
  - keeping the original split
  - reducing the split based on future contribution
  - buying out the exiting party
  - stopping commercial work entirely
- No change to ownership or revenue split should happen informally or by assumption.

## 10. Branding and Product Assets

- The MinuteWave name, brand, website copy, App Store listing, screenshots, and launch assets are part of the product package and should be treated as shared project assets unless otherwise agreed.
- If a rebrand happens later, both parties should approve it.

## 11. Confidentiality and Good Faith

- Both parties agree not to misuse private credentials, unreleased builds, revenue data, or internal strategy discussions.
- Both parties agree to act in good faith and not lock the other out of the project unfairly.

## 12. Next Step

If this collaboration continues beyond TestFlight and the first public launch, the parties should convert this memo into a more formal signed agreement.

Signed:

Leonard  
Date: __________

Maciej  
Date: __________
