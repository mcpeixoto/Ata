# Changelog

## 2.12.0

Two calls came back wrong — one with only your side in it, one with the other
side garbled — and nothing anywhere said so. This release is about that, plus
three things borrowed from Granola.

- **The other side of a call no longer comes out at double speed.** Since 2.11
  the system-audio track could play at about 2× while the file stayed the right
  length: each buffer held about half as many frames as the time since the last
  one, and the silence used to keep the two tracks in step filled the rest. The
  length check compared that padded file with the clock, so it never noticed.
  A buffer is now read in the layout it actually has — one the tap's format
  doesn't describe used to be dropped, which left a stretch of the track empty —
  and when the frames in an ordinary callback don't fill the time that just
  passed they are written at the rate they really arrived. The check looks at
  that, before any silence is added.   `Ata --diagnose` no longer quits the copy
  of Ata you already have open. Language-detection pieces left behind when a
  transcription stopped are removed the next time Ata starts. Recordings
  already on disk from 2.11 are repaired the next time Ata opens: the padding
  comes out, the speech is put back to the speed it was spoken, and the
  original file is kept as `system.corrupted`. Those meetings are transcribed
  again. The half of each buffer 2.11 never wrote is still gone.
- **One working microphone is a meeting in the room.** When the system-audio
  track is silent, Ata already tells the voices on your microphone apart. It
  now does the same when that track is loud but almost none of it comes back
  as words — the other side was never really captured, so the conversation is
  the one the microphone heard, and it is split into its speakers instead of
  all being filed as you. The lines that track did produce are left out: they
  are not the other participants.

- **A side of a call can no longer go missing in silence.** A system-audio tap
  pointed at an output the call is not using delivers perfect digital silence
  forever: buffers arrive, the file is the right length, every check Ata had
  passed. Now, half a minute into a recording where you have clearly been
  heard and their side has never risen above silence, Ata says so in the menu
  while the call can still be saved. And after transcription, if a track was
  present but held no sound, the transcript says so at the top and the meeting
  window shows it, with where to check. The echo canceller is also skipped
  against a silent reference — there is no echo to find, and it is the most
  expensive pass in the run.
- **Note templates.** Settings → Transcription: Standard (the shape Ata has
  always written), One-to-one, Sales call, Team standup, Interview. Templates
  apply when notes are written or rewritten.
- **Names and words to spell right.** A dictionary in Settings, with everyone
  you have named in People included automatically. With OpenAI the words go
  with the audio as spelling hints — "Copilot", not "copado" — and both
  summary writers are told to spell them as written.
- **Copy follow-up draft.** A button under a meeting's summary copies a
  follow-up email — subject, the overview, the action items as next steps —
  ready to paste into any mail app.

## 2.11.1

Ata as it stands:

- Records any meeting from the menu bar — your microphone and everything your
  Mac plays, two tracks, no bot joining the call — and notices meetings on its
  own when another app takes the microphone.
- Transcribes on this Mac with whisper.cpp or Apple speech recognition, or
  through the OpenAI API if you give it a key. Per-track languages, mixed
  languages in one call, re-transcription with a different model, and the old
  transcript kept beside the new one.
- Summaries with an overview, decisions, action items and open questions,
  written on this Mac by Apple Intelligence or by OpenAI.
- Knows who said what: voices are learned on this Mac, named once, and used in
  every transcript — including ones already written.
- Calendar-aware: offers to record before a meeting starts, files the
  recording under the meeting's own title, and suggests the invited people
  when it asks whose voice it heard.
- Every meeting is a plain folder of Markdown and audio, kept in iCloud if you
  turn that on, with an Insights view over all of them.
- iPhone and Apple Watch companions record in person and sync through iCloud.
- Recordings survive microphone switches, sleep, crashes and power loss;
  audio that comes out the wrong length is caught and reported, in plain
  words, instead of transcribing into nonsense quietly.
