# Changelog

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
