#!/usr/bin/env python3
"""Yearly Ata Pro, the 4.0 prices, the free trial, and the owner's offer code.

Reads App Store Connect and prints what it would change. Pass ``--apply`` to
write. Running it again changes nothing that already matches.

United States is the base price ($6.99 a month, $44.99 a year). Every territory
whose currency is EUR is pinned to 6.99 and 44.99 in euros, instead of whatever
Apple's equalization of the US price would be. Every other territory follows
that equalization. The monthly change sets ``preserveCurrentPrice``, so someone
already paying €2.99 keeps it.

The yearly subscription gets a one-week free introductory offer in each
territory, and one one-time offer code for a free year (Track 0 step 8). A
review screenshot for the new subscription is not something this API accepts.

The key is ``~/.appstoreconnect/private_keys/AuthKey_*.p8`` and the issuer is
``~/.appstoreconnect/issuer_id``, unless ``ASC_KEY_PATH``, ``ASC_KEY_ID`` and
``ASC_ISSUER`` are set. Same JWT as ``scripts/distribute-build.py``.
"""
import json, os, sys, time, urllib.error, urllib.parse, urllib.request
from datetime import date, timedelta
from decimal import Decimal
from pathlib import Path

API = "https://api.appstoreconnect.apple.com"
BUNDLE = "ai.interactive.ata"
GROUP = "Ata Pro"
MONTHLY = "ai.interactive.ata.pro.monthly"
YEARLY = "ai.interactive.ata.pro.yearly"
MONTHLY_PRICE = Decimal("6.99")
YEARLY_PRICE = Decimal("44.99")
LOCALIZATIONS = {
    "en-US": ("Ata Pro Yearly", "Unlimited meetings, billed yearly"),
    "pt-PT": ("Ata Pro Anual", "Reuniões ilimitadas, pagamento anual"),
}
OFFER_NAME = "Owner"


def credentials():
    key = os.environ.get("ASC_KEY_PATH", "")
    if not key:
        found = sorted(Path.home().glob(".appstoreconnect/private_keys/AuthKey_*.p8"),
                       key=lambda p: p.stat().st_mtime, reverse=True)
        if not found:
            sys.exit("No AuthKey_*.p8 under ~/.appstoreconnect/private_keys/")
        key = str(found[0])
    key_id = os.environ.get("ASC_KEY_ID") or Path(key).stem.removeprefix("AuthKey_")
    issuer = os.environ.get("ASC_ISSUER") or os.environ.get("ASC_ISSUER_ID", "")
    if not issuer:
        path = Path.home() / ".appstoreconnect" / "issuer_id"
        issuer = path.read_text().strip() if path.exists() else ""
    if not issuer:
        sys.exit("No issuer id. Set ASC_ISSUER or write ~/.appstoreconnect/issuer_id")
    return key, key_id, issuer


def token():
    import jwt  # PyJWT, the same library the release scripts use
    key, key_id, issuer = credentials()
    now = int(time.time())
    return jwt.encode(
        {"iss": issuer, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
        Path(key).read_text(),
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )


def call(tok, path, method="GET", body=None):
    url = path if path.startswith("https://") else API + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        url, data=data, method=method,
        headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=120) as res:
            raw = res.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")
        raise SystemExit(f"{method} {url} -> HTTP {e.code}\n{detail[:2000]}") from None


def pages(tok, path):
    rows = []
    included = []
    while path:
        payload = call(tok, path)
        rows.extend(payload.get("data") or [])
        included.extend(payload.get("included") or [])
        path = (payload.get("links") or {}).get("next")
    return rows, included


def index(included):
    return {(item["type"], item["id"]): item for item in included}


def money(value):
    return Decimal(str(value))


def territory_of(price, included):
    rel = ((price.get("relationships") or {}).get("territory") or {}).get("data") or {}
    return rel.get("id")


def point_of(price, included):
    rel = ((price.get("relationships") or {}).get("subscriptionPricePoint") or {}).get("data") or {}
    item = included.get((rel.get("type"), rel.get("id")))
    if not item:
        return None
    raw = (item.get("attributes") or {}).get("customerPrice")
    return money(raw) if raw is not None else None


def current_prices(tok, subscription):
    rows, extra = pages(tok, f"/v1/subscriptions/{subscription}/prices"
                             "?include=territory,subscriptionPricePoint&limit=200")
    found = index(extra)
    by_territory = {}
    for row in rows:
        territory = territory_of(row, found)
        amount = point_of(row, found)
        if territory and amount is not None:
            # A later start date is the scheduled price. No date is the one in force.
            start = (row.get("attributes") or {}).get("startDate") or ""
            previous = by_territory.get(territory)
            if previous is None or start >= previous[0]:
                by_territory[territory] = (start, amount)
    return {territory: amount for territory, (_, amount) in by_territory.items()}


def price_point(tok, subscription, territory, target):
    rows, _ = pages(tok, f"/v1/subscriptions/{subscription}/pricePoints"
                         f"?filter[territory]={urllib.parse.quote(territory)}"
                         "&fields[subscriptionPricePoints]=customerPrice&limit=8000")
    for row in rows:
        raw = (row.get("attributes") or {}).get("customerPrice")
        if raw is not None and money(raw) == target:
            return row["id"]
    return None


def equalized(tok, point_id):
    # `territory` has to be in the sparse fieldset or the relationship is omitted.
    rows, extra = pages(
        tok,
        f"/v1/subscriptionPricePoints/{point_id}/equalizations"
        "?include=territory&limit=8000"
        "&fields[subscriptionPricePoints]=customerPrice,territory")
    found = index(extra)
    out = {}
    for row in rows:
        territory = territory_of(row, found)
        raw = (row.get("attributes") or {}).get("customerPrice")
        if territory and raw is not None:
            out[territory] = (row["id"], money(raw))
    return out


def currencies(tok):
    rows, _ = pages(tok, "/v1/territories?limit=200&fields[territories]=currency")
    return {row["id"]: (row.get("attributes") or {}).get("currency", "") for row in rows}


def planned_points(tok, subscription, base_point, euro, target):
    """USA at ``target``, each euro territory pinned to the same number, and the
    equalization of the US point everywhere else. Returns point ids and amounts."""
    points = {"USA": base_point}
    amounts = {"USA": target}
    for territory in sorted(euro):
        if territory == "USA":
            continue
        found = price_point(tok, subscription, territory, target)
        if not found:
            raise SystemExit(f"No {target} price point for {subscription} in {territory}")
        points[territory] = found
        amounts[territory] = target
    for territory, (point, amount) in equalized(tok, base_point).items():
        if territory not in points:
            points[territory] = point
            amounts[territory] = amount
    return points, amounts


def availability_territories(tok, subscription):
    """The territories a subscription is sold in, or None when it has no availability yet."""
    try:
        row = call(tok, f"/v1/subscriptions/{subscription}/subscriptionAvailability").get("data")
    except SystemExit as e:
        if "HTTP 404" in str(e):
            return None
        raise
    rows, _ = pages(tok, f"/v1/subscriptionAvailabilities/{row['id']}/availableTerritories?limit=200")
    return sorted(r["id"] for r in rows)


def ensure_availability(tok, source, target, apply):
    wanted = availability_territories(tok, source) or []
    have = availability_territories(tok, target)
    if have is not None and set(wanted) <= set(have):
        print(f"\nyearly availability: {len(have)} territories, already there")
        return
    print(f"\nyearly availability: {len(wanted)} territories, same as monthly")
    if apply:
        call(tok, "/v1/subscriptionAvailabilities", "POST", {"data": {
            "type": "subscriptionAvailabilities",
            "attributes": {"availableInNewTerritories": True},
            "relationships": {
                "subscription": {"data": {"type": "subscriptions", "id": target}},
                "availableTerritories": {"data": [{"type": "territories", "id": t} for t in wanted]},
            },
        }})


def create_price(tok, subscription, point, territory, preserve):
    attributes = {}
    if preserve:
        # A change to an approved subscription needs a start date: without one Apple
        # reads the request as the initial price and answers 409. Apple wants it at
        # least two days out (measured 2026-11-22: "must be on or after 2026-11-24").
        attributes["preserveCurrentPrice"] = True
        attributes["startDate"] = (date.today() + timedelta(days=2)).isoformat()
    call(tok, "/v1/subscriptionPrices", "POST", {"data": {
        "type": "subscriptionPrices",
        "attributes": attributes,
        "relationships": {
            "subscription": {"data": {"type": "subscriptions", "id": subscription}},
            "territory": {"data": {"type": "territories", "id": territory}},
            "subscriptionPricePoint": {"data": {"type": "subscriptionPricePoints", "id": point}},
        },
    }})


def print_price_diff(current, planned, territory_currency, euro):
    pinned = ["USA"] + sorted(t for t in planned if t in euro)
    others = sorted(t for t in planned if t not in pinned)
    for territory in pinned + others:
        now = current.get(territory)
        target = planned.get(territory)
        currency = territory_currency.get(territory, "")
        mark = "keep" if now == target else "change"
        print(f"  {territory:4} {currency:4} {now if now is not None else '—':>8} -> {target}  {mark}")
    if not others:
        print("  (no equalized territories — the US price point returned none)")


def main() -> int:
    apply = "--apply" in sys.argv
    if any(arg not in ("--apply", "--dry-run") for arg in sys.argv[1:]):
        sys.exit("usage: asc-pricing.py [--dry-run | --apply]")
    tok = token()
    apps = call(tok, f"/v1/apps?filter[bundleId]={BUNDLE}")["data"]
    if not apps:
        sys.exit(f"No app for {BUNDLE}")
    app = apps[0]["id"]
    groups, _ = pages(tok, f"/v1/apps/{app}/subscriptionGroups?limit=200")
    group = next((g for g in groups if (g.get("attributes") or {}).get("referenceName") == GROUP), None)
    if group is None:
        sys.exit(f"No subscription group named {GROUP}")
    subs, _ = pages(tok, f"/v1/subscriptionGroups/{group['id']}/subscriptions?limit=200")
    by_product = {(s.get("attributes") or {}).get("productId"): s for s in subs}
    monthly = by_product.get(MONTHLY)
    yearly = by_product.get(YEARLY)
    if monthly is None:
        sys.exit(f"{MONTHLY} is not in the {GROUP} group")

    print(f"app {app}  group {group['id']} {GROUP}")
    print(f"monthly {monthly['id']}  yearly {yearly['id'] if yearly else '(missing)'}")
    print("mode", "apply" if apply else "dry-run")

    territory_currency = currencies(tok)
    euro = sorted(code for code, currency in territory_currency.items() if currency == "EUR")
    print(f"euro territories ({len(euro)}): {', '.join(euro)}")

    monthly_now = current_prices(tok, monthly["id"])
    usa_monthly = price_point(tok, monthly["id"], "USA", MONTHLY_PRICE)
    if not usa_monthly:
        sys.exit(f"No {MONTHLY_PRICE} price point for monthly in USA")
    print("\nmonthly prices (current -> planned, preserve current price for existing subscribers):")
    monthly_plan, monthly_amounts = planned_points(tok, monthly["id"], usa_monthly, euro, MONTHLY_PRICE)
    print_price_diff(monthly_now, monthly_amounts, territory_currency, euro)
    if apply:
        for territory, point in monthly_plan.items():
            if monthly_now.get(territory) == monthly_amounts.get(territory):
                continue
            create_price(tok, monthly["id"], point, territory, preserve=True)
            print(f"  set {territory}")

    if yearly is None:
        print(f"\nyearly: create {YEARLY} in {GROUP}, period ONE_YEAR")
        for locale, (name, description) in LOCALIZATIONS.items():
            print(f"  localization {locale}: {name} — {description}")
        print(f"  price USA ${YEARLY_PRICE}, euro territories €{YEARLY_PRICE}, "
              "other territories equalized from USA")
        print("  introductory offer FREE_TRIAL ONE_WEEK x1 on every priced territory")
        print(f"  offer code {OFFER_NAME}: FREE_TRIAL ONE_YEAR, auto-renew off, "
              "one one-time PRODUCTION code, valid for a year")
        if not apply:
            print("\ndry-run: nothing written")
            return 0
        created = call(tok, "/v1/subscriptions", "POST", {"data": {
            "type": "subscriptions",
            "attributes": {
                "name": "Ata Pro Yearly",
                "productId": YEARLY,
                "subscriptionPeriod": "ONE_YEAR",
                "familySharable": False,
                "reviewNote": "Yearly Ata Pro. One week free, then the yearly price. "
                              "Same group as the monthly plan.",
            },
            "relationships": {"group": {"data": {"type": "subscriptionGroups", "id": group["id"]}}},
        }})
        yearly = created["data"]
        print(f"  created {yearly['id']}")

    yearly_id = yearly["id"]
    existing_locales, _ = pages(tok, f"/v1/subscriptions/{yearly_id}/subscriptionLocalizations?limit=200")
    have = {(row.get("attributes") or {}).get("locale") for row in existing_locales}
    for locale, (name, description) in LOCALIZATIONS.items():
        if locale in have:
            print(f"yearly localization {locale}: already there")
            continue
        print(f"yearly localization {locale}: create {name}")
        if apply:
            call(tok, "/v1/subscriptionLocalizations", "POST", {"data": {
                "type": "subscriptionLocalizations",
                "attributes": {"name": name, "locale": locale, "description": description},
                "relationships": {"subscription": {"data": {"type": "subscriptions", "id": yearly_id}}},
            }})

    # A new subscription is sold nowhere until it has an availability, and Apple
    # refuses a price in a territory it is not sold in. Same territories as monthly.
    ensure_availability(tok, monthly["id"], yearly_id, apply)

    usa_yearly = price_point(tok, yearly_id, "USA", YEARLY_PRICE)
    if not usa_yearly:
        sys.exit(f"No {YEARLY_PRICE} price point for yearly in USA")
    yearly_now = current_prices(tok, yearly_id)
    yearly_plan, yearly_amounts = planned_points(tok, yearly_id, usa_yearly, euro, YEARLY_PRICE)
    print("\nyearly prices (no existing subscribers, so the price is not preserved):")
    print_price_diff(yearly_now, yearly_amounts, territory_currency, euro)
    if apply:
        for territory, point in yearly_plan.items():
            if yearly_now.get(territory) == yearly_amounts.get(territory):
                continue
            create_price(tok, yearly_id, point, territory, preserve=False)

    # Without include=territory the relationship comes back empty and every
    # territory looks missing, so a second run would try to create them again.
    intro, _ = pages(tok, f"/v1/subscriptions/{yearly_id}/introductoryOffers?include=territory&limit=200")
    intro_territories = set()
    for row in intro:
        attrs = row.get("attributes") or {}
        if attrs.get("offerMode") != "FREE_TRIAL" or attrs.get("duration") != "ONE_WEEK":
            continue
        rel = ((row.get("relationships") or {}).get("territory") or {}).get("data") or {}
        if rel.get("id"):
            intro_territories.add(rel["id"])
    missing_intro = [t for t in sorted(yearly_plan) if t not in intro_territories]
    print(f"\nyearly introductory offer: FREE_TRIAL ONE_WEEK already on {len(intro_territories)}, "
          f"missing {len(missing_intro)}")
    if apply:
        for territory in missing_intro:
            call(tok, "/v1/subscriptionIntroductoryOffers", "POST", {"data": {
                "type": "subscriptionIntroductoryOffers",
                "attributes": {"duration": "ONE_WEEK", "numberOfPeriods": 1, "offerMode": "FREE_TRIAL"},
                "relationships": {
                    "subscription": {"data": {"type": "subscriptions", "id": yearly_id}},
                    "territory": {"data": {"type": "territories", "id": territory}},
                },
            }})

    codes, _ = pages(tok, f"/v1/subscriptions/{yearly_id}/offerCodes?limit=200")
    owner = next((row for row in codes if (row.get("attributes") or {}).get("name") == OFFER_NAME), None)
    if owner is None:
        print(f"\noffer code {OFFER_NAME}: create FREE_TRIAL ONE_YEAR, auto-renew off, "
              "eligibilities NEW EXISTING EXPIRED")
        if apply:
            # The prices relationship is required and names the territories the
            # code can be redeemed in; a free trial has no price point (Apple
            # answers 409 if one is given). USA and Portugal cover the owner.
            included = []
            pointers = []
            for i, territory in enumerate(("USA", "PRT")):
                local = "${price" + str(i) + "}"
                pointers.append({"type": "subscriptionOfferCodePrices", "id": local})
                included.append({
                    "type": "subscriptionOfferCodePrices",
                    "id": local,
                    "relationships": {
                        "territory": {"data": {"type": "territories", "id": territory}},
                    },
                })
            created = call(tok, "/v1/subscriptionOfferCodes", "POST", {
                "data": {
                    "type": "subscriptionOfferCodes",
                    "attributes": {
                        "name": OFFER_NAME,
                        "customerEligibilities": ["NEW", "EXISTING", "EXPIRED"],
                        # Apple refuses a code without auto-renew stacked on the
                        # week's trial; the free year replaces the trial instead.
                        "offerEligibility": "REPLACE_INTRO_OFFERS",
                        "duration": "ONE_YEAR",
                        "offerMode": "FREE_TRIAL",
                        "numberOfPeriods": 1,
                        "autoRenewEnabled": False,
                    },
                    "relationships": {
                        "subscription": {"data": {"type": "subscriptions", "id": yearly_id}},
                        "prices": {"data": pointers},
                    },
                },
                "included": included,
            })
            owner = created["data"]
    else:
        print(f"\noffer code {OFFER_NAME}: already {owner['id']}")

    if owner is not None:
        existing_codes, _ = pages(tok, f"/v1/subscriptionOfferCodes/{owner['id']}/oneTimeUseCodes?limit=200")
        state = (call(tok, f"/v1/subscriptions/{yearly_id}").get("data", {}).get("attributes") or {}).get("state")
        if existing_codes:
            print(f"  one-time code: already {len(existing_codes)} batch(es); not creating another")
        elif state != "APPROVED":
            # Apple makes codes only for an approved subscription; yearly is approved
            # with the 4.0 review. Run this script again after that.
            print(f"  one-time code: yearly is {state}; codes can be made once it is APPROVED")
        else:
            # Apple caps a one-time code's expiry at six months out.
            expires = (date.today() + timedelta(days=180)).isoformat()
            print(f"  one-time code: 1 PRODUCTION code, expires {expires}")
            if apply:
                call(tok, "/v1/subscriptionOfferCodeOneTimeUseCodes", "POST", {"data": {
                    "type": "subscriptionOfferCodeOneTimeUseCodes",
                    "attributes": {
                        "numberOfCodes": 1,
                        "expirationDate": expires,
                        "environment": "PRODUCTION",
                    },
                    "relationships": {
                        "offerCode": {"data": {"type": "subscriptionOfferCodes", "id": owner["id"]}},
                    },
                }})

    if apply:
        print("\nread back:")
        for label, sub in (("monthly", monthly["id"]), ("yearly", yearly_id)):
            got = current_prices(tok, sub)
            interesting = ["USA"] + euro
            for territory in interesting:
                amount = got.get(territory)
                print(f"  {label:8} {territory:4} {territory_currency.get(territory, ''):4} {amount}")
    else:
        print("\ndry-run: nothing written")
    return 0


if __name__ == "__main__":
    sys.exit(main())
