#!/bin/zsh
# Signs Mimiuchi.app with the local signing identity (see setup-signing.sh) so that the
# Input Monitoring and Accessibility permissions keep working after rebuilds.
#
#   Scripts/sign.sh path/to/Mimiuchi.app
set -euo pipefail
APP="${1:?usage: Scripts/sign.sh path/to/Mimiuchi.app}"
APP="${APP:a}"  # relative to the caller's directory
cd "$(dirname "$0")/.."

[[ -d "$APP" ]] || { echo "error: $APP not found" >&2; exit 1; }
DIR="${MIMIUCHI_SIGNING_DIR:-$HOME/Library/Application Support/Mimiuchi-Signing}"
KC="$DIR/signing.keychain-db"
ENTITLEMENTS="Mimiuchi/Mimiuchi.entitlements"

HASH="$(Scripts/setup-signing.sh)"

# codesign only looks for identities in the user's keychain search list, so add the signing
# keychain for the duration of the signature and always put the original list back.
ORIGINAL_KEYCHAINS=("${(@f)$(security list-keychains -d user | sed -E 's/^[[:space:]]*"(.*)"[[:space:]]*$/\1/')}")
ORIGINAL_KEYCHAINS=(${ORIGINAL_KEYCHAINS:#})        # drop empty entries
ORIGINAL_KEYCHAINS=(${ORIGINAL_KEYCHAINS:#$KC})     # left over from an interrupted run
restore_keychains() { security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}"; }
trap restore_keychains EXIT
trap 'restore_keychains; exit 130' INT TERM
security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" "$KC"

codesign --force --options runtime --timestamp=none \
  --entitlements "$ENTITLEMENTS" --sign "$HASH" "$APP"
codesign --verify --strict "$APP"
echo "Signed with the local identity: $(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"
