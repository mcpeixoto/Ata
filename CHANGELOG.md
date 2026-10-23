# Changelog

## Unreleased

- **Transcribe with Apple's speech recognition.** On macOS 26, **Settings → Transcription** has a
  third engine, **On this Mac (Apple)**: free, nothing leaves the Mac, and no whisper.cpp to
  install. macOS downloads the speech model for each language the first time, or when you click
  **Download speech model**. Every word keeps its time, so following along, the speaker split and
  echo removal work as with whisper.cpp.
- **Portuguese and English in one call, with Apple's engine too.** With the language on
  **Automatic**, Ata transcribes the track in each of your languages and keeps, for every stretch
  between pauses, the one it was spoken in.
- A language Apple's recognizer doesn't offer yet fails with a clear message and keeps the audio,
  so you can transcribe it again with whisper.cpp.

## 2.5.0

- **Follow the meeting word by word.** While a meeting plays, the word being said is highlighted
  in the transcript, the words still to come are dimmed, and the view scrolls along. Click any
  word, or a timestamp, to jump the audio there. Meetings transcribed earlier work too, with
  estimated word times.
- **See who spoke when.** The player's bar becomes a waveform: the others above the line, you
  below, each in their colour. Click or drag to jump; hover to see the time. Your lane comes from
  the microphone with the others taken out, so only your voice shows there.
- **Summaries on this Mac.** With Apple Intelligence (macOS 26), the summary and **Write notes**
  are written by Apple's on-device model: free, and nothing leaves the Mac. Long meetings are
  summarized in parts and then combined. Older Macs, or languages Apple's model doesn't write
  yet, keep using OpenAI. Choose the engine in **Settings → Transcription**.
- **Voices you don't want.**
  - **Don't ask about this voice** stops Ata asking for a name.
  - **Leave out of transcripts** drops a voice's lines from every transcript, past ones
    included, for a TV in the background, a meeting bot, or someone who asked not to be
    transcribed. The recording itself is untouched, and both can be undone from **Hidden
    voices** in the People tab.
- OpenAI's whisper-1 now returns word times too.

## 2.4.2

- **Fixed: switching between Portuguese and English in the same call.** Ata picked one language
  per track, so once you switched, whatever you said in the other language came out garbled or
  even translated.
- **How it works now:** each stretch of speech gets its own language. Ata cuts the track at
  pauses, detects the language of each piece in a single pass, and transcribes every run in the
  language it was spoken. It never translates.
  - A language only counts when Whisper is sure, it's one of your Mac's languages, and it lasts
    at least 3 seconds, so a short "okay" doesn't switch.
  - A call in one language is transcribed exactly as before.
- This is for the local engine with the language set to Automatic. With OpenAI, Automatic
  already lets OpenAI detect the language.

## 2.4.1

- **Fixed: without headphones, the others' words showed up as yours.** Your microphone hears
  the other participants through the Mac's speakers, and Ata transcribed them a second time
  under your name. The old fix compared words after transcribing, and missed the echo whenever
  it was misheard or came out in another language.
- **How it's fixed:** Ata now takes the others out of a copy of your microphone track before
  transcribing, using what your Mac played as the reference.
  - It finds the delay and the room's echo, and corrects drift between the microphone's clock
    and external speakers.
  - With headphones it finds no echo and leaves your microphone exactly as recorded.
  - The recording itself is never changed.
  - In tests with real speech, the echo dropped 31–36 dB while only the others spoke, and your
    own speech was left intact, even when you spoke over them.
- **Transcribe again** applies the fix to older meetings too. It can be turned off in
  **Settings → Transcription**.

## 2.4.0

- **Every meeting in its own window.** Click a meeting in the menu to listen to it, read its
  notes and transcript, and name the people in it:
  - a player with ±15 s skips and 1×–2× speed; click any line of the transcript to play from
    there, and the line being heard is highlighted as you listen;
  - **Notes**: the AI summary, or **Write notes** to create one for a meeting transcribed without
    it (sends the transcript text to OpenAI, never the audio), plus your own notes, saved as
    `notes.md` in the meeting folder;
  - a searchable transcript;
  - **People**: every voice in the meeting, with a play button and a name field, so a voice heard
    only once can be named too;
  - **Share** the audio, the transcript, the notes, or audio and transcript together, through
    AirDrop, Mail, Messages or any app's share extension; the files are named after the meeting.
    Drag the MP3 out of the player straight into another app;
  - copy the transcript or notes, **Save as MP3…**, transcribe again, or delete.
- **The whole meeting as one MP3.** Ata mixes your microphone and the others into
  `meeting.mp3` next to the transcript (48 kbps, about 21 MB an hour) as soon as a recording
  stops, so you can listen before the transcript is ready. The separate tracks are kept for
  transcribing again. **Meetings recorded before 2.4 get theirs too**: after updating, Ata works
  through your history in the background, newest first, one meeting at a time — and any meeting
  whose audio is still there can be heard, shared and saved as MP3 from its window right away.
  Off in **Settings → Audio** if you'd rather not.
- **Choose how the menu bar icon looks while recording**, in **Settings → Menu bar**: a record
  dot, a waveform, a microphone or Ata's glyph; in the menu bar's colour, red, or your accent
  colour; with or without the timer; pulsing or still. Transcription progress can be hidden too.
- The "Transcript ready" notification opens the meeting window.
- MP3 encoding uses [LAME](https://lame.sourceforge.io) 3.100, built in from source.

## 2.3.1

- **Fixed: Ata kept asking for system-audio permission you had already given.** It recorded
  system audio through screen capture, which needs *Screen Recording* and is only reported as
  granted after a relaunch. Ata now records system audio with Core Audio under the audio-only
  **System Audio Recording Only** permission — never your screen — asks once, and restarts
  itself once right after you allow it. Requires macOS 14.2.
- **Fixed: a keychain password prompt could block Ata at launch.** Checking whether an OpenAI
  key was stored read the key itself, which macOS can answer with a keychain prompt; Ata now
  only reads the key when it calls OpenAI.
- A damaged audio file now fails with an error instead of giving a shorter transcript.
- Summaries are written in your language and region: European Portuguese in Portugal.
- From a full review:
  - discarding a recording could make the next one stop itself after 10 seconds;
  - meetings stayed queued after a model download until the next recording;
  - with OpenAI, one silent stretch erased every timestamp, and models without timestamps
    could attribute ten minutes of speech to one named person; long chunks for the
    gpt-4o models could be cut short;
  - OpenAI rate limits and server errors are retried instead of failing the meeting;
  - quitting mid-transcription no longer leaves whisper-cli running, and the meeting is
    transcribed on next launch;
  - the updater no longer freezes the menu, won't restart during a recording, and won't
    install a release your macOS can't run;
  - audio retention and update checks run every few hours, not only at launch;
  - deleting a meeting removes it from the voice library; an unreadable library is never
    overwritten; an empty name shows as "Me"; update errors appear in the menu.
- `Ata --diagnose` prints what Ata can access and records five seconds of each track, for bug
  reports.

## 2.3.0

- **Know who said what.** Turn on voice recognition in the new **People** tab and Ata tells the
  other participants apart, learns their voices across meetings, and asks about a voice once it
  has heard it twice: play a short sample, type a name, and every transcript — past ones
  included — uses it. Unnamed voices keep a stable number ("Voice 3") everywhere.
- Lines are split where the speaker changes, word by word, rather than following Whisper's
  segments, which run across turns.
- Merge two voices that are the same person, rename, forget one or all.
- All on this Mac: voice fingerprints and samples never leave it, even when OpenAI transcribes.
  The first time it runs, Ata downloads 21 MB of on-device models
  ([FluidAudio](https://github.com/FluidInference/FluidAudio), Core ML). Off by default; needs
  macOS 15, since an Apple bug in macOS 14 crashes the pipeline.
- **Fixed: updating left the old copy running.** It hung while quitting, so two Ata icons sat in
  the menu bar after an update. Ata now quits cleanly, and on launch it ends any stale copy left
  behind by an update from 2.1 or 2.2. Updates also wait until a recording has finished.
- `Ata.app/Contents/MacOS/Ata --update-now` checks for and installs an update without the UI.
- Transcripts are now also saved as `transcript.json` (segments with speaker labels), so names
  can change without transcribing again.
- For contributors: FluidAudio is the project's first dependency; Package.swift now uses tools
  6.2 (Xcode 26), and every `swift` command takes `--disable-keychain`.

## 2.2.0

- **Better local transcripts.** Measured on 425 runs of real European Portuguese and English
  speech, clean and over VoIP and phone-quality audio
  ([numbers](docs/plans/2026-10-v2.2-v2.3.md)):
  - the decoding settings that caused repetition loops and clipped the first words of short
    turns are fixed — VoIP meeting error rate down from 32% to 21%;
  - the new default model, **Large v3**, is the most accurate on Portuguese and noisy calls, and a
    smaller download than before (1.08 GB). **Turbo** and **Turbo compact** remain for speed or
    disk space. Existing installs keep working on their model until they switch;
  - "Automatic" language now detects each track separately and only accepts languages you
    actually use — no more English meetings transcribed as Welsh.
- **Transcribe again with any model.** Right-click a meeting → *Transcribe again with…* any
  downloaded local model or any OpenAI model. The previous transcript is kept in the meeting's
  `versions/` folder — nothing is overwritten.
- **Insights.** A new tab in the menu: hours recorded, meetings per week, words, who talks how
  much, which apps your meetings happen in, every transcription with its model and cost, and
  how much transcribing on your Mac saved. Charts and numbers animate in. Meetings from before
  2.2 are included, read from their transcripts.
- **Costs.** Every transcription records its engine, model, audio minutes and — for OpenAI — an
  estimated price, in `meeting.json`.
- **Fixed:** several Settings texts were never translated to Portuguese; a symlinked model
  counted as not downloaded; the transcript's date followed the system region instead of the
  transcript's language.
- For contributors: unit tests (`swift test`) run in CI, plus an opt-in end-to-end test that
  transcribes a Portuguese and English meeting with a real model (`ATA_AUDIO_TESTS=1`);
  `check-localization.sh` now also fails when code uses a string missing from
  the tables, and `scripts/lib/sync-strings.py` adds and prunes keys in every language at once.

## 2.1.0

First public release.

- **OpenAI transcription engine** alongside the local whisper.cpp one, picked in Settings or
  from the welcome window. The API key is stored in the login keychain.
- **AI summary** — overview, decisions, action items and open questions above the
  transcript, available with either engine.
- **Audio is kept by default** and compressed to m4a (roughly a tenth of the raw size), with
  an optional 7/30/90-day retention.
- **Automatic updates**: Ata checks this repository daily and installs a new release after
  verifying its signature, Apple notarization and Team ID.
- **English and Portuguese**, following the system language.
- Signed with a Developer ID and notarized, published as a DMG by CI on every `v*` tag.
- Transcripts are now `transcript.md`; existing `transcricao.md` files are still read.
- Open-source groundwork: README with light and dark screenshots rendered from the real UI
  (`scripts/snapshots.sh`, also run by CI on every pull request), contributing guide,
  architecture notes, code of conduct, security policy, PR and issue templates, and English
  comments throughout the code.

## 2.0

Internal release: menu bar app, two-track recording, meeting detection, local whisper.cpp
transcription, echo removal, crash recovery.
