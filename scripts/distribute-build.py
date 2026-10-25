#!/usr/bin/env python3
"""Give the build just uploaded to a TestFlight group, so somebody can actually install it.

`xcrun altool --upload-app` finishes when App Store Connect has the binary. That is not the
same as a tester having it: a build with no beta group is VALID, READY_FOR_BETA_TESTING and
invisible in the TestFlight app to everybody, forever. Every build this project ever
uploaded sat in that state — builds 1, 3, 4, 6 and 7, across six weeks — and every upload
job was green, because "uploaded" was the only thing anyone checked.

Assigns the newest build to every internal group on the app. Internal groups only: an
external group means beta review, which is a submission and a decision for a person.
"""
import json, os, sys, time, urllib.request

API = "https://api.appstoreconnect.apple.com/v1/"


def token() -> str:
    import jwt  # PyJWT, installed by the workflow step that calls this
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER"], "iat": now, "exp": now + 900,
         "aud": "appstoreconnect-v1"},
        open(os.environ["ASC_KEY_PATH"]).read(),
        algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
    )


def call(tok, path, method="GET", body=None):
    req = urllib.request.Request(
        API + path, method=method,
        headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json"},
        data=json.dumps(body).encode() if body else None)
    resp = urllib.request.urlopen(req)
    raw = resp.read()
    return json.loads(raw) if raw else {}


def main() -> int:
    tok = token()
    bundle = os.environ.get("BUNDLE_ID", "com.peixotolabs.polaris")
    want = os.environ.get("BUILD_VERSION", "")
    want_build = os.environ.get("BUILD_NUMBER", "").strip()
    if not want_build:
        print("::error::BUILD_NUMBER is empty. Without it this cannot tell this run's build "
              "from the previous release's, and would distribute the wrong one.")
        return 1

    apps = call(tok, f"apps?filter[bundleId]={bundle}")["data"]
    if not apps:
        print(f"::error::No app in App Store Connect for {bundle}")
        return 1
    app = apps[0]["id"]

    # The build this run made, found by its number rather than by being newest.
    #
    # "Newest by upload date" was the original rule and it shipped the wrong build twice:
    # App Store Connect does not list a build the moment altool finishes, so seconds after
    # the upload the newest visible build is still the previous release's — already VALID,
    # so the wait exits at once and distributes it. v0.12.0 handed testers v0.11.1.
    #
    # Processing is also asynchronous, so a build can be listed and not yet distributable.
    deadline = time.time() + 900
    while True:
        builds = call(tok, f"builds?filter[app]={app}&limit=20&sort=-uploadedDate"
                           "&include=preReleaseVersion")["data"]
        build = next((b for b in builds
                      if b["attributes"]["version"] == want_build), None)

        if build is None:
            if time.time() > deadline:
                seen = ", ".join(b["attributes"]["version"] for b in builds[:5]) or "none"
                print(f"::error::Build {want_build} never appeared in App Store Connect "
                      f"after 15 minutes. Newest seen: {seen}.")
                return 1
            print(f"build {want_build} not listed yet; waiting")
            time.sleep(30)
            continue

        num = build["attributes"]["version"]
        state = build["attributes"]["processingState"]
        if state == "VALID":
            break
        if state in ("INVALID", "FAILED"):
            print(f"::error::Build {num} finished processing as {state}. Apple usually "
                  f"emails the reason; nothing can be distributed.")
            return 1
        if time.time() > deadline:
            print(f"::error::Build {num} still {state} after 15 minutes.")
            return 1
        print(f"build {num} is {state}; waiting")
        time.sleep(30)

    # And it must be the version this run built. A build number that matched something
    # unexpected would otherwise ship the wrong app under the right number.
    if want:
        inc = call(tok, f'builds/{build["id"]}?include=preReleaseVersion').get("included", [])
        got = next((i["attributes"]["version"] for i in inc
                    if i["type"] == "preReleaseVersions"), "")
        if got and got != want:
            print(f"::error::Build {num} is version {got}, not {want}. Refusing to "
                  f"distribute a build this run did not produce.")
            return 1

    groups = [g for g in call(tok, f"betaGroups?filter[app]={app}")["data"]
              if g["attributes"].get("isInternalGroup")]
    if not groups:
        print("::error::No internal TestFlight group exists on this app. Create one in "
              "App Store Connect — until then an uploaded build reaches nobody.")
        return 1

    for g in groups:
        call(tok, f'betaGroups/{g["id"]}/relationships/builds', "POST",
             {"data": [{"type": "builds", "id": build["id"]}]})
        print(f'build {num} -> {g["attributes"]["name"]}')

    check = call(tok, f'builds/{build["id"]}?include=betaGroups')
    named = [i["attributes"]["name"] for i in check.get("included", [])
             if i["type"] == "betaGroups"]
    if not named:
        print("::error::The build still belongs to no group after assignment.")
        return 1
    print(f"distributed to: {', '.join(named)}")
    print(f"marketing version {want or '?'}, build {num}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
