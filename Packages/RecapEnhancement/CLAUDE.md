# RecapEnhancement

On-device note enhancement via Apple FoundationModels. No transcription/capture logic and no
UI — turns a transcript + raw notes into enhanced Markdown notes. Depends on RecapCore only.

## Key files
- `FoundationModelEnhancer.swift` (289 lines, largest) — orchestrates the map/merge/reduce
  enhancement pipeline: chunk transcript → per-chunk `ChunkDigest` (`@Generable`: keyPoints,
  decisions, actionItems) → merge digests → final notes.
- `FoundationModelBackend.swift` — thin wrapper around the Apple FoundationModels session/API.
- `TranscriptChunker.swift` — splits long transcripts into model-sized chunks.
- `TextOverlap.swift` — dedupes/stitches overlapping chunk boundaries.
- `DigestSanitizer.swift` — guards against schema-echo garbage and trivial-transcript output
  before it reaches the final notes (see recent fix in git history — cde1361).

## Test
`swift test --package-path Packages/RecapEnhancement`.

## Gotchas
- Needs real Apple Intelligence availability to run for real; `enhance-probe` exits `2` and
  `enhance-eval` exits `69` when unavailable (`enhance-eval` also uses `66` for a missing
  fixtures dir). Tests use fakes/backends, not live Apple Intelligence.
- `enhance-probe <transcript.json> [notes.md]` is a manual harness against a real transcript.
- `enhance-eval [--runs N] [--show] [fixtures-dir]` scores `Fixtures/enhance/` cases — run
  before/after any enhancement prompt change; `--json` prints one final-line JSON object with
  per-case `structure`/`recall`/`meta`/`numbers`/`subtitle` booleans.
- `@Generable` structs (e.g. `ChunkDigest`) need an explicit memberwise `init` — the macro's
  synthesized one isn't reliably usable from test code across the module boundary.
