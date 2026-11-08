#!/usr/bin/env python3
"""Installs the "Ata Developer ID" provisioning profile, which the Mac release embeds.

iCloud on the Mac only syncs a container for an app that is entitled to it, and iCloud
entitlements are restricted: a Developer ID build has to carry a profile that allows
them, or it is killed at launch. scripts/build-app.sh embeds this one by name.

The profile (MAC_APP_DIRECT, bundle ai.interactive.ata, the Developer ID Application
certificate) already exists on the account; this only downloads it.

  ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER in the environment.
"""
import base64, json, os, plistlib, subprocess, sys, time, urllib.parse, urllib.request
from pathlib import Path

API = "https://api.appstoreconnect.apple.com/v1/"
NAME = "Ata Developer ID"
DEST = Path.home() / "Library/MobileDevice/Provisioning Profiles"


def token() -> str:
    import jwt  # PyJWT, supplied by the caller
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER"], "iat": now, "exp": now + 900,
         "aud": "appstoreconnect-v1"},
        Path(os.environ["ASC_KEY_PATH"]).read_text(),
        algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})


def main() -> int:
    query = urllib.parse.urlencode({"filter[name]": NAME, "filter[profileState]": "ACTIVE"})
    req = urllib.request.Request(API + "profiles?" + query, headers={"Authorization": "Bearer " + token()})
    found = json.loads(urllib.request.urlopen(req).read()).get("data", [])
    if not found:
        print(f"No active '{NAME}' profile on the account. Create it in the developer portal:"
              " Developer ID, bundle ai.interactive.ata, the Developer ID Application certificate.",
              file=sys.stderr)
        return 1
    content = base64.b64decode(found[0]["attributes"]["profileContent"])
    decoded = subprocess.run(["security", "cms", "-D"], input=content, capture_output=True, check=True).stdout
    profile = plistlib.loads(decoded)
    containers = profile.get("Entitlements", {}).get("com.apple.developer.ubiquity-container-identifiers", [])
    if "iCloud.ai.interactive.ata" not in containers:
        print(f"'{NAME}' does not allow the iCloud container; turn iCloud on for the bundle ID and regenerate it.",
              file=sys.stderr)
        return 1
    DEST.mkdir(parents=True, exist_ok=True)
    path = DEST / f"{profile['UUID']}.provisionprofile"
    path.write_bytes(content)
    print(f"{NAME}: {path.name}, expires {profile['ExpirationDate']:%Y-%m-%d}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
