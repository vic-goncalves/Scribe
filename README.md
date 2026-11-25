# Scribe

https://github.com/user-attachments/assets/99663534-4dc5-4a2c-bbe7-f35a4b69ed59

A Mac app that transcribes audio locally with OpenAI's Whisper (via [WhisperKit](https://github.com/argmaxinc/WhisperKit), CoreML on Apple Silicon) and separates speakers with SpeakerKit. Audio and transcripts never leave the machine; the only network access is the one-time download of the speech and speaker models from Hugging Face.

- Drop audio files (mp3, m4a, wav, flac, aiff, caf) anywhere in the window, use "New transcript" (⌘N), or "Open With > Scribe" in Finder.
- Files are copied into a local library and transcribed in a background queue.
- Transcripts are grouped into timestamped paragraphs. Click any sentence or timestamp to play from there; the playing sentence is highlighted.
- Speakers are identified on-device (SpeakerKit, pyannote CoreML models). Click a speaker label to rename that speaker everywhere or move a paragraph to another speaker. Exports include speaker names.
- Fuzzy search across every transcript (typo-tolerant), jumping to the matching moment.
- Copy, or export as .txt, .md, .docx or .srt.
- Speech models (Fast / Balanced / Best) can be downloaded, switched and deleted from the model switcher at the bottom of the sidebar.

## Install

On an Apple Silicon Mac with macOS 15 or later, paste this into Terminal (it also updates an existing install):

```sh
curl -fsSL https://github.com/vic-goncalves/Scribe/releases/latest/download/Scribe.zip -o /tmp/Scribe.zip && rm -rf /Applications/Scribe.app && ditto -xk /tmp/Scribe.zip /Applications && open /Applications/Scribe.app
```

The app isn't notarized. Installing through Terminal like this avoids the "unidentified developer" block; if you download the zip in a browser instead, allow it under System Settings > Privacy & Security > Open Anyway.

## Requirements

macOS 15+, Apple Silicon, Xcode 16+ (Swift 6 toolchain).

## Build and run

```sh
./scripts/build-app.sh            # builds build/Scribe.app
./scripts/build-app.sh --install  # also copies it to /Applications
```

The app is ad-hoc signed for local use (not notarized).

To publish a release, bump `CFBundleShortVersionString` in `Resources/Info.plist`, commit, then run `./scripts/release.sh`.

## Tests

```sh
swift test                                                         # unit tests
SCRIBE_INTEGRATION=1 swift test --filter TranscriberIntegrationTests  # downloads the small model (~220 MB, cached), transcribes synthesized speech and checks two voices get separate speakers
```

## Where data lives

`~/Library/Application Support/Scribe/`: `library.sqlite` (recordings, segments with speakers, speaker names, FTS5 trigram index), `Audio/` (imported files), `Models/` (Whisper models, tokenizers and speaker models).

For development, `SCRIBE_ROOT=/some/dir` points the app at a separate library, models folder and settings:

```sh
open -n --env SCRIBE_ROOT=/tmp/scribe-dev build/Scribe.app
```

## Code map

- `Library.swift`: storage (GRDB/SQLite), import, fuzzy search.
- `Transcriber.swift`: model download/switching, the transcription queue and speaker identification.
- `Player.swift`: audio playback.
- `TranscriptFormatting.swift`: paragraph grouping and exports.
- `SidebarView.swift`, `RecordingDetailView.swift`, `MainView.swift`, `SetupView.swift`, `ModelPickerView.swift`, `Theme.swift`: UI.
- `scripts/make-icon.swift`: renders `Resources/AppIcon.icns`.

## Known limits

Speaker separation is reliable for a few distinct voices on reasonably clean audio. Crosstalk, short interjections and similar voices can be misattributed; fix those from the speaker label menu.
