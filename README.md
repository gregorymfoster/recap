# Recap

**Private, offline meeting transcription for your Mac.**

Recap records your meetings (your mic *and* the other participants via system audio — no bot joins your call), transcribes them entirely on-device with open-source Whisper models, and turns your rough in-meeting bullets into polished notes using Apple's on-device language model.

**Nothing ever leaves your Mac.** No account, no cloud, no subscription.

> 🚧 Recap is under active development and not yet released. Watch the repo for the first build.

## How it works

1. Hit **Record** when your meeting starts. Type rough, lazy notes — fragments are fine.
2. Recap captures mic + system audio and transcribes on-device in the background, as a low-priority job that pauses on battery.
3. When you stop, your bullets are expanded into structured notes using the transcript — your structure, the meeting's specifics.

Everything is stored as plain Markdown and audio files in a folder you choose (default `~/Recap`), readable by any app, forever.

## Requirements

- macOS 26 or later, Apple silicon recommended
- ~500 MB disk for the recommended Whisper Small model (downloaded in-app)
- Note enhancement uses Apple Intelligence when available; transcription works regardless

## Build from source

```sh
brew install xcodegen
git clone https://github.com/gregorymfoster/recap.git && cd recap
./Scripts/bootstrap.sh   # generates Recap.xcodeproj and opens it
```

The core logic lives in plain Swift packages under `Packages/` — `swift test` works from any package directory without Xcode project generation.

## Privacy model

- Audio, transcripts, and notes are written only to your chosen local folder.
- Models are downloaded once from Hugging Face; transcription and enhancement run fully offline.
- The app makes no other network connections (auto-update checks via Sparkle can be disabled in Settings).

## License

[MIT](LICENSE)
