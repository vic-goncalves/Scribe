# Scribe

A Mac app that transcribes audio locally with OpenAI's Whisper (via [WhisperKit](https://github.com/argmaxinc/WhisperKit), CoreML on Apple Silicon). Audio and transcripts never leave the machine; the only network access is downloading a speech model.

- Drop audio files (mp3, m4a, wav, flac, aiff, caf) anywhere in the window, use "New transcript" (⌘N), or "Open With > Scribe" in Finder.
- Files are copied into a local library and transcribed in a background queue.
- Transcripts are grouped into timestamped paragraphs. Click any sentence or timestamp to play from there; the playing sentence is highlighted.
- Fuzzy search across every transcript (typo-tolerant), jumping to the matching moment.
- Copy, or export as .txt, .md, .docx or .srt.
- Speech models (Fast / Balanced / Best) can be downloaded, switched and deleted from the model switcher at the bottom of the sidebar.

## Requirements

macOS 15+, Apple Silicon, Xcode 16+ (Swift 6 toolchain).

## Build and run

```sh
./scripts/build-app.sh            # builds build/Scribe.app
./scripts/build-app.sh --install  # also copies it to /Applications
```

The app is ad-hoc signed for local use (not notarized).

## Tests

```sh
swift test                                                         # unit tests
SCRIBE_INTEGRATION=1 swift test --filter TranscriberIntegrationTests  # downloads the small model (~220 MB, cached) and transcribes synthesized speech
```

## Where data lives

`~/Library/Application Support/Scribe/`: `library.sqlite` (recordings, segments, FTS5 trigram index), `Audio/` (imported files), `Models/` (downloaded models and tokenizers).

For development, `SCRIBE_ROOT=/some/dir` points the app at a separate library, models folder and settings:

```sh
open -n --env SCRIBE_ROOT=/tmp/scribe-dev build/Scribe.app
```

## Code map

- `Library.swift`: storage (GRDB/SQLite), import, fuzzy search.
- `Transcriber.swift`: model download/switching and the transcription queue.
- `Player.swift`: audio playback.
- `TranscriptFormatting.swift`: paragraph grouping and exports.
- `SidebarView.swift`, `RecordingDetailView.swift`, `MainView.swift`, `SetupView.swift`, `ModelPickerView.swift`, `Theme.swift`: UI.
- `scripts/make-icon.swift`: renders `Resources/AppIcon.icns`.

## Not yet

Speaker separation (diarization). WhisperKit ships SpeakerKit, which is the likely path.
