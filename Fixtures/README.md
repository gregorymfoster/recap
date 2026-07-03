# Test fixtures

- `meeting-fixture.m4a` — 31s synthetic meeting speech (macOS `say`), used for
  repeatable manual verification of transcription without a real meeting:

  ```sh
  swift run --package-path Packages/RecapTranscription transcribe-probe Fixtures/meeting-fixture.m4a tiny
  swift run --package-path Packages/RecapTranscription transcribe-probe Fixtures/meeting-fixture.m4a tiny --stream
  ```

- `two-speaker-fixture.m4a` — 47s synthetic two-person meeting (macOS `say`,
  Samantha and Daniel alternating turns with 400 ms gaps), used to verify
  speaker diarization end to end. Expected: alternating turns, two speakers
  (an occasional spurious extra cluster on the final tail is a known
  diarization artifact):

  ```sh
  swift run --package-path Packages/RecapTranscription diarize-probe Fixtures/two-speaker-fixture.m4a
  ```

- `enhance/` — (transcript, notes, expectations) triples for the enhancement
  quality scorecard. Run after any prompt change:

  ```sh
  swift run --package-path Packages/RecapEnhancement enhance-eval --runs 2
  ```

  Metrics: structure (one bullet per note line), recall (expected specifics
  present), meta (no narration), numbers (no digits absent from the source —
  hallucination proxy), dupes ("Also discussed" restating a note bullet).

  To enhance a single transcript/notes pair manually (e.g. one of the
  `enhance/` cases) and inspect the raw output, use `enhance-probe` instead —
  needs Apple Intelligence enabled on this Mac (exits 2 if unavailable):

  ```sh
  swift run --package-path Packages/RecapEnhancement enhance-probe <transcript.json> [notes.md]
  ```

- `transcribe/` — (reference transcript, expectations) cases for the
  transcription quality scorecard, scored by word error rate (WER). Run after
  any model default or decoding-option change:

  ```sh
  swift run --package-path Packages/RecapTranscription transcribe-eval Fixtures/transcribe
  ```

  Each case dir has `reference.txt` (ground-truth transcript) and
  `expectations.json` (`{"maxWER": 0.25, "model": "tiny"}`). Case audio comes
  from an explicit `expectations.json` `"audio"` path, a case-local
  `audio.m4a`, or — for `meeting-fixture`, which has neither — the shared
  `Fixtures/meeting-fixture.m4a` above, so the binary isn't duplicated.
  `meeting-fixture/reference.txt` was drafted from a `base`-model transcription
  and lightly hand-corrected; **treat it as a first draft and verify it against
  the actual `say`-spoken script before trusting eval failures.** Exits
  nonzero if any case exceeds its `maxWER`. Not run in normal (push/PR) CI —
  see the `transcription-eval` job in `.github/workflows/ci.yml`, which runs
  nightly and on `workflow_dispatch`.
