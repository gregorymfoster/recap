# RecapAudio

Mic + system-audio capture, mixing, and transcoding. No transcription/ML logic (RecapTranscription)
and no UI (RecapUI) — this package only produces mixed/transcoded audio and capture events.
Depends on RecapCore for shared types (`AudioChunk`, etc.).

## Key files
- `MeetingRecorder.swift` (510 lines, largest file) — orchestrates a recording session: starts
  mic + system audio sources, drives the mixer, writes output, handles pause/resume/stop and
  spool salvage on write failure.
- `SystemAudioTap.swift` — `@MainActor` Core Audio process-tap capture (the modern
  "System Audio Recording Only" permission path, not full Screen Recording).
- `MicSource.swift` — `AVAudioEngine` mic capture; installs a `@Sendable` tap block that runs
  nonisolated on the engine's realtime thread.
- `MixBuffer.swift` — pairwise-drains mic + system audio to keep them aligned; pads the stalled
  side with silence past a starvation threshold. `AudioPipeline.mixerSampleRate` = 48 kHz is the
  shared pipeline constant.
- `MonoMixer.swift` — sums the two aligned streams to mono.
- `AudioTranscoder.swift` — encodes mixed audio to the on-disk `.m4a`.
- `ProcessAudioMonitor.swift` / `CallAudioActivityTracker.swift` — CoreAudio process metadata
  for call-app start/stop detection, no TCC prompt required.
- `SyntheticAudioSource.swift` — synthetic source used by `-soak` mode (no real hardware).

## Test
`swift test --package-path Packages/RecapAudio`. `GoldenAudioTests` compares against recorded
fixtures — check it first if audio-path changes seem to regress output.

## Gotchas
- Realtime audio callbacks (mic tap, tap IOProc) must be `@Sendable`; a non-Sendable closure
  captured there SIGTRAPs at runtime under Swift 6 strict concurrency, not a compile error.
- `capture-probe` (`swift run --package-path Packages/RecapAudio capture-probe 5`) needs mic TCC
  and hits real hardware — manual verification only, not CI. `call-audio-probe` needs no TCC
  (CoreAudio metadata only).
- `SystemAudioTap` failures almost always mean a denied System Audio Recording permission,
  not a code bug — check `SystemAudioProbeResult` mapping before deep-diving.
