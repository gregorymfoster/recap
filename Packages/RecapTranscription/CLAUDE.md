# RecapTranscription

Transcription (WhisperKit) and diarization (FluidAudio) engines implementing RecapCore's
engine protocols. No audio capture (RecapAudio) and no UI (RecapUI) — this package only turns
audio into text/speaker turns. Depends on RecapCore for `AudioChunk`, `TranscriptionUpdate`, etc.

## Key files
- `WhisperKitEngine.swift` — `TranscriptionEngine` conformance; file-path transcription re-runs
  the full saved recording after a meeting ends (one pipeline instance per call — the queue
  runs one job at a time, keeping idle memory near zero).
- `WhisperModelManager.swift` — `@MainActor @Observable`; downloads/tracks/activates WhisperKit
  models under `~/Library/Application Support/Recap/Models` (HubApi layout). Downloads resume
  incrementally if paused.
- `StreamingPass.swift` — live/streaming transcription pass used during an active recording.
- `SpeakerDiarizer.swift` / `SpeakerAssignment.swift` — FluidAudio-backed diarization and
  mapping speaker turns onto transcript utterances.
- `ModelCatalog.swift` — available Whisper model variants/metadata.
- `WordErrorRate.swift` — WER scoring used by `transcribe-eval`.

## Test
`swift test --package-path Packages/RecapTranscription`.

## Gotchas
- WhisperKit models download on first run (`transcribe-probe`, `enhance` pipeline) — not
  hermetic, expect network + disk on a clean machine.
- `transcribe-probe <audio-file> [variant] [--stream] [--language <code>] [--json]` and
  `diarize-probe <audio-file> [--json]` are manual-verification harnesses against real
  models, not run in CI.
- `transcribe-eval [--json] Fixtures/transcribe` scores WER against fixtures — run before/after
  any model default or decoding-option change; it's nightly/`workflow_dispatch` only in CI
  (`transcription-eval` job), not per-PR.
- `--json` mode always prints exactly one JSON object as the last stdout line; human output
  is unchanged otherwise.
