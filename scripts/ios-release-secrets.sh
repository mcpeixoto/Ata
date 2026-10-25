#!/usr/bin/env bash
# Which secrets ios-release.yml needs, which this repo has, and how to set the rest.
#
# The recurring failure this exists to end: a release day arrives, the workflow fails on a
# secret nobody knew was missing, and somebody has to find out where the credential lives
# and what it is called. All five answers are knowable in advance. This asks GitHub what is
# set, looks on this machine for what is not, and — with --set — puts them in place.
#
#   scripts/ios-release-secrets.sh          what is configured and what each gap costs
#   scripts/ios-release-secrets.sh --set    set the ones sourceable from this machine
#
# Nothing here prints a secret value. --set streams a credential from a local file straight
# into `gh secret set` without it passing through a variable, a log or a terminal.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

SET=0
[ "${1:-}" = "--set" ] && SET=1

command -v gh >/dev/null || { echo "gh is not installed; nothing can be checked." >&2; exit 1; }

have=$(gh secret list --json name --jq '.[].name' 2>/dev/null || true)
configured() { grep -qx "$1" <<<"$have"; }

green=0; gaps=()
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; green=$((green+1)); }
gap() { printf '  \033[31m✗\033[0m %-22s %s\n' "$1" "$2"; gaps+=("$1"); }

printf '\n\033[1mTestFlight — ios-release.yml on a v* tag\033[0m\n'
for s in APPLE_API_KEY_PATH APPLE_API_KEY_ID APPLE_API_ISSUER; do
  configured "$s" && ok "$s" || gap "$s" "no build is ever uploaded"
done
# Separate from the API key, and not implied by it. -allowProvisioningUpdates downloads a
# certificate; the private key that makes it an identity lives only in the keychain whose
# CSR created it, and no App Store Connect role can hand one out.
for s in IOS_DIST_P12 IOS_DIST_P12_PASSWORD; do
  configured "$s" && ok "$s" || gap "$s" "the archive cannot be signed — no distribution private key"
done

asc_key=$(ls -t "$HOME"/.appstoreconnect/private_keys/AuthKey_*.p8 2>/dev/null | head -1 || true)
asc_key_id=""
[ -n "$asc_key" ] && asc_key_id=$(basename "$asc_key" .p8 | sed 's/^AuthKey_//')
# The issuer is not a credential. It is already in the repo's own setup script, or in the
# file the maintainer's Mac keeps it in.
asc_issuer=$(grep -rhoE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
             --include='asc-setup.py' . 2>/dev/null | head -1 || true)
[ -n "$asc_issuer" ] || asc_issuer=$(cat "$HOME/.appstoreconnect/issuer_id" 2>/dev/null | tr -d '[:space:]' || true)
iosid=$(security find-identity -v -p codesigning 2>/dev/null | grep 'Apple Distribution' | head -1 | sed 's/.*"\(.*\)"/\1/' || true)

printf '\n\033[1mOn this machine\033[0m\n'
[ -n "$asc_key" ]    && ok "App Store Connect key   $asc_key"    || printf '  \033[31m✗\033[0m No AuthKey_*.p8 under ~/.appstoreconnect/private_keys/\n'
[ -n "$asc_issuer" ] && ok "Issuer id               $asc_issuer" || printf '  \033[31m✗\033[0m No issuer id in an asc-setup.py or ~/.appstoreconnect/issuer_id\n'
[ -n "$iosid" ]      && ok "iOS identity            $iosid"      || printf '  \033[31m✗\033[0m No "Apple Distribution" identity in the keychain\n'

if [ ${#gaps[@]} -eq 0 ]; then
  printf '\n%s secrets configured. Nothing missing.\n' "$green"
  exit 0
fi

printf '\n\033[1m%d missing.\033[0m ' "${#gaps[@]}"
if [ $SET -eq 0 ]; then
  echo "Run with --set to configure the three sourceable from this machine."
  echo
  echo "The .p12 is not automated, because exporting it needs the login keychain password:"
  echo
  echo "  security export -k login.keychain-db -t identities -f pkcs12 \\"
  echo "    -P \"\$PW\" -o /tmp/dist.p12   # \$PW is a passphrase you choose, not your login password"
  echo "  base64 -i /tmp/dist.p12 | gh secret set IOS_DIST_P12"
  echo "  gh secret set IOS_DIST_P12_PASSWORD --body \"\$PW\" && rm /tmp/dist.p12"
  echo
  echo "One export serves every app in this account — the same identity signs all of them."
  exit 0
fi

printf 'Setting what can be sourced locally.\n\n'
if [ -n "$asc_key" ] && [ -n "$asc_issuer" ]; then
  configured APPLE_API_KEY_PATH || { gh secret set APPLE_API_KEY_PATH < "$asc_key" && echo "  set APPLE_API_KEY_PATH from $asc_key"; }
  configured APPLE_API_KEY_ID   || { gh secret set APPLE_API_KEY_ID --body "$asc_key_id" && echo "  set APPLE_API_KEY_ID"; }
  configured APPLE_API_ISSUER   || { gh secret set APPLE_API_ISSUER --body "$asc_issuer" && echo "  set APPLE_API_ISSUER"; }
else
  echo "  the App Store Connect key or issuer is not on this machine; nothing to set" >&2
fi
printf '\nThe .p12 pair stays manual: see the commands printed without --set.\n'
