"""Writes made-up meeting folders for scripts/snapshots.sh.

Nothing here is real: names, apps, durations and costs are invented so the
README screenshots look like a lived-in install without showing anyone's data.
Usage: python3 -I make-fixtures.py <meetings dir>
"""
import json
import os
import random
import sys
from datetime import datetime, timedelta, timezone

out = sys.argv[1]
now = datetime.now(timezone.utc).replace(microsecond=0)
random.seed(7)  # same screenshots every run


def iso(d):
    return d.strftime("%Y-%m-%dT%H:%M:%SZ")


def record(engine, model, finished, minutes, cost, my_share):
    words = int(minutes * 125)
    talk = minutes * 60 * 0.82
    return {
        "engine": engine,
        "model": model,
        "finishedAt": iso(finished),
        "audioSeconds": minutes * 120,
        "processingSeconds": minutes * 9,
        "costUSD": cost,
        "words": words,
        "mySpeechSeconds": round(talk * my_share, 1),
        "othersSpeechSeconds": round(talk * (1 - my_share), 1),
    }


def meeting(folder, app, ago_minutes, minutes, status="done", records=None, audio_mb=0):
    d = os.path.join(out, folder)
    os.makedirs(d, exist_ok=True)
    start = now - timedelta(minutes=ago_minutes)
    body = {
        "id": folder,
        "app": app,
        "startedAt": iso(start),
        "endedAt": iso(start + timedelta(minutes=minutes)),
        "duration": minutes * 60,
        "status": status,
    }
    if records:
        body["transcriptions"] = records
    with open(os.path.join(d, "meeting.json"), "w") as f:
        json.dump(body, f, indent=2)
    if audio_mb:
        for track in ("mic.m4a", "system.m4a"):
            with open(os.path.join(d, track), "wb") as f:
                f.truncate(audio_mb * 1024 * 1024 // 2)


LOCAL = ("local", "large-v3-q5_0")

# The five most recent: these appear in the menu screenshots.
meeting("fixture-slack", "Slack", 40, 32, status="transcribing")
meeting("fixture-zoom", "Zoom", 190, 47, audio_mb=22,
        records=[record("openai", "whisper-1", now - timedelta(minutes=140), 47, 0.0, 0.41)
                 | {"costUSD": 0.564, "archivedAs": "earlier whisper-1.md"},
                 record(*LOCAL, now - timedelta(minutes=120), 47, 0.0, 0.41)])
meeting("fixture-meet", "Chrome", 1500, 28, audio_mb=13,
        records=[record("openai", "gpt-4o-transcribe", now - timedelta(minutes=1460), 28, 0.341, 0.52)])
meeting("fixture-teams", "Teams", 2950, 61, audio_mb=28,
        records=[record(*LOCAL, now - timedelta(minutes=2880), 61, 0.0, 0.33)])
meeting("fixture-ft", "FaceTime", 4400, 12, audio_mb=6,
        records=[record(*LOCAL, now - timedelta(minutes=4380), 12, 0.0, 0.58)])

# Older history, spread over the last eight weeks, for the charts.
apps = ["Zoom", "Zoom", "Slack", "Chrome", "Teams", "Slack", "Zoom", "Chrome"]
for i in range(22):
    days = 4 + i * 2.4 + random.random()
    minutes = random.choice([15, 25, 30, 45, 50, 60, 75])
    finished = now - timedelta(days=days) + timedelta(minutes=minutes + 5)
    use_openai = i % 6 == 0
    rec = (record("openai", "whisper-1", finished, minutes, round(minutes * 2 * 0.006, 3), 0.4)
           if use_openai else record(*LOCAL, finished, minutes, 0.0, random.uniform(0.3, 0.5)))
    meeting(f"fixture-old-{i:02d}", apps[i % len(apps)], int(days * 1440), minutes, records=[rec])

# Voices for the People tab: two recurring voices to name, three named people.
# Written to the support folder the snapshot run points ATA_SUPPORT_DIR at.
support = os.environ.get("ATA_FIXTURE_SUPPORT")
if support:
    import uuid
    voices_dir = os.path.join(support, "voices")
    os.makedirs(voices_dir, exist_ok=True)

    def iso_ms(d):
        return d.strftime("%Y-%m-%dT%H:%M:%S.000Z")

    def voice(name, meetings, last_days, me=False):
        vid = str(uuid.UUID(int=random.getrandbits(128))).upper()
        sample = f"{vid}.m4a"
        open(os.path.join(voices_dir, sample), "wb").close()
        return {
            "id": vid, "name": name, "centroid": [1.0, 0.0, 0.0], "observations": meetings,
            "meetingIDs": [f"fixture-old-{i:02d}" for i in range(meetings)], "sample": sample,
            "firstSeen": iso_ms(now - timedelta(days=50)), "lastSeen": iso_ms(now - timedelta(days=last_days)),
            "isMe": me,
        }

    voices = [
        voice(None, 6, 0.1), voice(None, 3, 2),
        voice("Rita Almeida", 14, 0.2), voice("João Costa", 9, 1), voice("Sam Patel", 4, 6),
        voice("Alex", 27, 0.1, me=True),
    ]
    with open(os.path.join(voices_dir, "voices.json"), "w") as f:
        json.dump([{k: v for k, v in x.items() if v is not None} for x in voices], f, indent=2)
