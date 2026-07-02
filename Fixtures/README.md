# Test fixtures

- `meeting-fixture.m4a` — 31s synthetic meeting speech (macOS `say`), used for
  repeatable manual verification of transcription without a real meeting:

  ```sh
  swift run --package-path Packages/RecapTranscription transcribe-probe Fixtures/meeting-fixture.m4a tiny
  swift run --package-path Packages/RecapTranscription transcribe-probe Fixtures/meeting-fixture.m4a tiny --stream
  ```
