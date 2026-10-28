#!/usr/bin/env python3
"""Put the App Store provisioning profiles this export names onto the machine doing it.

A manual-signing export fails with "No 'iOS App Store' profiles for team X matching 'Y' are
installed" unless the profile is already in ~/Library/MobileDevice/Provisioning Profiles.
-allowProvisioningUpdates does not fetch it: it creates Xcode-managed profiles, and a named
profile is not one. On the maintainer's Mac the profiles are there because a setup script
installed them once, which is exactly why the export worked by hand and failed on a fresh
runner at the end of a ten-minute archive.

Reads the profile names out of the ExportOptions plist, so there is one list, not two.

  ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER, EXPORT_OPTIONS (and IOS_DIR) in the environment.

It also prints which certificates each profile carries. An export signs with an identity
from the keychain, and a profile that does not list that certificate is refused — with a
message about the profile rather than about the certificate, so the pairing is worth seeing
before the archive rather than after it.
"""
import base64, json, os, plistlib, subprocess, sys, time, urllib.request
from pathlib import Path

API = "https://api.appstoreconnect.apple.com/v1/"
DEST = Path.home() / "Library/MobileDevice/Provisioning Profiles"


def token() -> str:
    import jwt  # PyJWT, installed by the caller
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER"], "iat": now, "exp": now + 900,
         "aud": "appstoreconnect-v1"},
        Path(os.environ["ASC_KEY_PATH"]).read_text(),
        algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})


def get(tok, path):
    req = urllib.request.Request(API + path, headers={"Authorization": "Bearer " + tok})
    return json.loads(urllib.request.urlopen(req).read())


def keychain_identities() -> set[str]:
    """Common names of the codesigning identities available here, for the warning below."""
    out = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"],
                         capture_output=True, text=True).stdout
    return {line.split('"')[1] for line in out.splitlines() if '"' in line}


def main() -> int:
    ios_dir = Path(os.environ.get("IOS_DIR", "."))
    opts = ios_dir / os.environ["EXPORT_OPTIONS"]
    if not opts.is_file():
        print(f"::error::{opts} does not exist; nothing says which profiles this export needs")
        return 1
    wanted = plistlib.loads(opts.read_bytes()).get("provisioningProfiles") or {}
    if not wanted:
        print(f"::error::{opts} names no provisioningProfiles. A manual-signing export cannot proceed.")
        return 1

    tok = token()
    profiles = {p["attributes"]["name"]: p for p in get(tok, "profiles?limit=200")["data"]}
    identities = keychain_identities()
    DEST.mkdir(parents=True, exist_ok=True)

    missing, installed = [], []
    for bundle, name in sorted(wanted.items()):
        p = profiles.get(name)
        if p is None:
            missing.append(f"{name} (for {bundle})")
            continue
        attrs = p["attributes"]
        if attrs.get("profileState") != "ACTIVE":
            print(f"::warning::profile {name} is {attrs.get('profileState')}, not ACTIVE")
        out = DEST / f"{attrs['uuid']}.mobileprovision"
        out.write_bytes(base64.b64decode(attrs["profileContent"]))
        certs = get(tok, f"profiles/{p['id']}/certificates"
                         "?fields[certificates]=displayName,certificateType,expirationDate")["data"]
        names = [f"{c['attributes']['certificateType']} {c['id']}" for c in certs]
        print(f"{name} -> {out.name}  expires {attrs.get('expirationDate', '?')}  certs: {', '.join(names) or 'none'}")
        installed.append(name)

    if missing:
        print("::error::These profiles do not exist in App Store Connect: "
              + "; ".join(missing)
              + ". Create them (the repo's asc-setup.py does) or correct the names in "
              + str(opts) + ".")
        return 1

    # The pairing that actually decides whether the export works. Said plainly here because
    # xcodebuild reports it as a missing profile.
    if identities:
        print(f"signing identities available here: {', '.join(sorted(identities))}")
    print(f"{len(installed)} profile(s) installed into {DEST}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
