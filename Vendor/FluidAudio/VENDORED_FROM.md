Upstream source: `https://github.com/FluidInference/FluidAudio`

- Base tag: `v0.12.1`
- Base commit: `1cf23303`
- Vendored on: `2026-03-27`

Local changes applied for Swift strict concurrency compatibility:

1. `Sources/FluidAudio/ASR/AsrManager.swift`
   - Marked `AsrManager` as `@unchecked Sendable`
2. `Sources/FluidAudio/ASR/Streaming/StreamingAsrManager.swift`
   - Removed `nonisolated(unsafe)` from actor-owned model properties
   - Kept those properties actor-isolated so Swift 6 enforces the boundary

This vendor copy intentionally trims unused upstream targets from the package manifest:

- Removed the TTS product and targets
- Removed the CLI target
- Excluded `TTS` sources from the `FluidAudio` target
- Kept only the targets used by MinuteWave: `FluidAudio`, `FastClusterWrapper`, `MachTaskSelfWrapper`

When upstream ships an equivalent fix in a tagged release, replace the path dependency in the root `Package.swift` with the upstream package again.
