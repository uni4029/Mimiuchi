#!/bin/zsh
# Creates (once) a local self-signed code-signing identity for Mimiuchi and prints its SHA-1.
#
# Why: macOS binds privacy permissions (Input Monitoring and Accessibility, needed for ⌘C+C) to the app's code
# signature. An ad-hoc signature changes with every build, so after a rebuild the switch in
# System Settings stays on but no longer applies to the new app. Signing every build with the
# same local certificate keeps the designated requirement
#     identifier "local.mimiuchi.Mimiuchi" and certificate leaf = H"<sha1>"
# unchanged, so the permission survives rebuilds.
#
# The identity lives in its own keychain (not the login keychain), so no password prompts are
# needed. The certificate is not trusted system-wide; it is only used to sign this app locally.
# Remove it with:  rm -rf "$HOME/Library/Application Support/Mimiuchi-Signing"
#
#   Scripts/setup-signing.sh          # create if missing, print the identity hash
#   Scripts/setup-signing.sh --check  # print the hash if it exists, exit 1 otherwise
set -euo pipefail

DIR="${MIMIUCHI_SIGNING_DIR:-$HOME/Library/Application Support/Mimiuchi-Signing}"
KC="$DIR/signing.keychain-db"
PW_FILE="$DIR/keychain-password"
NAME="Mimiuchi Local Code Signing"
OPENSSL=/usr/bin/openssl  # LibreSSL: its PKCS#12 format is what `security import` expects

identity_hash() {
  security find-identity -p codesigning "$KC" 2>/dev/null \
    | awk -v name="\"$NAME\"" 'index($0, name) { print $2; exit }'
}

if [[ -f "$KC" && -f "$PW_FILE" ]]; then
  security unlock-keychain -p "$(<"$PW_FILE")" "$KC"
  hash="$(identity_hash)"
  if [[ -n "$hash" ]]; then
    echo "$hash"
    exit 0
  fi
  echo "error: $KC exists but contains no \"$NAME\" identity (delete $DIR to recreate it)" >&2
  exit 1
fi
[[ "${1:-}" == "--check" ]] && exit 1

mkdir -p "$DIR"
chmod 700 "$DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
trap 'rm -rf "$TMP"; exit 130' INT TERM HUP  # zsh skips EXIT traps on these signals
umask 077

cat > "$TMP/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 -config "$TMP/openssl.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
p12_password="$("$OPENSSL" rand -hex 16)"
"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/identity.p12" -passout "pass:$p12_password"

keychain_password="$("$OPENSSL" rand -hex 24)"
printf '%s' "$keychain_password" > "$PW_FILE"
security create-keychain -p "$keychain_password" "$KC"
security set-keychain-settings "$KC"  # never auto-lock
security unlock-keychain -p "$keychain_password" "$KC"
security import "$TMP/identity.p12" -k "$KC" -P "$p12_password" -T /usr/bin/codesign >/dev/null
# Let codesign use the key without a confirmation dialog.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$KC" >/dev/null

hash="$(identity_hash)"
[[ -n "$hash" ]] || { echo "error: failed to create the signing identity" >&2; exit 1; }
echo "Created local signing identity \"$NAME\" ($hash) in $KC" >&2
echo "$hash"
