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
