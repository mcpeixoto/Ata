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


CATEGORIES = {"Zoom": "work", "Slack": "work", "Teams": "work", "FaceTime": "personal"}


def meeting(folder, app, ago_minutes, minutes, status="done", records=None, audio_mb=0, category=None):
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
    # Work or personal: guessed from the app, as Ata does, unless given.
    value = category or CATEGORIES.get(app)
    if value:
        body["category"] = {"value": value, "manual": category is not None, "at": iso(start)}
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
        records=[record(*LOCAL, now - timedelta(minutes=120), 47, 0.0, 0.41)])
meeting("fixture-meet", "Chrome", 1500, 28, audio_mb=13, category="personal",
        records=[record(*LOCAL, now - timedelta(minutes=1460), 28, 0.0, 0.52)])
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
    rec = record(*LOCAL, finished, minutes, 0.0, random.uniform(0.3, 0.5))
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

    # The meeting window: fixture-zoom gets a transcript, a summary, your notes,
    # and two voices — one named, one waiting for a name.
    zoom = os.path.join(out, "fixture-zoom")
    lines = [
        (0, 6, "me", "Morning both. Shall we start with the launch date?"),
        (7, 15, "S1", "Yes. Design is done; the last thing is the onboarding copy, which I can finish by Wednesday."),
        (16, 22, "S2", "QA needs two days after that, so Friday works if nothing slips."),
        (23, 29, "me", "Friday it is. Rita, can you send the copy to Sam when it's ready?"),
        (30, 34, "S1", "Will do. I'll also update the screenshots."),
        (35, 44, "S2", "One open question: do we keep the old pricing page live during the switch?"),
        (45, 52, "me", "Let's decide that Thursday, once we see the numbers from the beta."),
        (53, 58, "S1", "Sounds good. I'll book thirty minutes."),
    ]
    summary = (
        "**Overview** — The team agreed to launch on Friday, once the onboarding copy is finished "
        "and QA has had two days with it.\n\n"
        "**Decisions**\n- Launch on Friday.\n\n"
        "**Action items**\n- Rita: finish the onboarding copy by Wednesday and send it to Sam.\n"
        "- Rita: update the screenshots.\n- Rita: book a 30-minute check-in on Thursday.\n\n"
        "**Open questions**\n- Keep the old pricing page live during the switch?"
    )
    with open(os.path.join(zoom, "transcript.json"), "w") as f:
        json.dump({
            "segments": [{"start": a * 1000, "end": b * 1000, "speaker": sp, "text": t} for a, b, sp, t in lines],
            "coarse": False, "summary": summary, "engine": "local", "model": "large-v3-q5_0",
        }, f, indent=2)
    # The player's waveform: 50 ms levels per lane, loud where each side speaks.
    import struct, math
    buckets = 58 * 20
    me_lane = bytearray(buckets); others_lane = bytearray(buckets)
    for a, b, sp, _ in lines:
        lane = me_lane if sp == "me" else others_lane
        for i in range(a * 20, min(buckets, b * 20)):
            syllable = 0.55 + 0.45 * abs(math.sin(i * 0.9)) * (0.6 + 0.4 * random.random())
            lane[i] = int(150 + 90 * syllable) if random.random() > 0.08 else 60
    with open(os.path.join(zoom, "waveform.bin"), "wb") as f:
        f.write(b"ATAW" + bytes([1]) + struct.pack("<HI", 50, buckets) + bytes(me_lane) + bytes(others_lane))
    with open(os.path.join(zoom, "transcript.md"), "w") as f:
        f.write("# Zoom\n")
    with open(os.path.join(zoom, "notes.md"), "w") as f:
        f.write("Ask Sam about the beta numbers before Thursday.\nCheck the pricing page copy with legal.\n")
    rita = next(v for v in voices if v["name"] == "Rita Almeida")
    unnamed = voices[1]
    with open(os.path.join(zoom, "speakers.json"), "w") as f:
        json.dump({
            "speakers": [
                {"label": "S1", "embedding": [1.0, 0.0, 0.0], "seconds": 22.0, "voiceID": rita["id"]},
                {"label": "S2", "embedding": [0.0, 1.0, 0.0], "seconds": 15.0, "voiceID": unnamed["id"]},
            ],
            "turns": [{"start": a * 1000, "end": b * 1000, "label": sp} for a, b, sp, _ in lines if sp != "me"],
        }, f, indent=2)
