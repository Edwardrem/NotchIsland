#!/bin/zsh
# Creates (once) the self-signed "NotchIsland Developer" code-signing identity in its own keychain.
#
# Why: macOS ties permission grants (Full Disk Access, Accessibility) to the app's code signature.
# An ad-hoc signature is a hash of the binary, so every rebuild silently invalidates the grants and
# the app is back to "authorization denied". Signing every release with the same certificate keeps
# them across updates. Gatekeeper treats it like an unsigned app (right-click ▸ Open), same as before.
#
# Usage: scripts/signing-identity.sh            create if missing, print status
#        scripts/signing-identity.sh --unlock   unlock the keychain and print its path (make-dmg.sh)
#
# Nothing here is committed: the keychain lives in ~/Library/Keychains and its password in ~/.config.
# Keep both. A new identity means users have to grant permissions once more after updating.
set -euo pipefail

NAME="NotchIsland Developer"
KEYCHAIN="$HOME/Library/Keychains/notchisland-signing.keychain-db"
PASSFILE="$HOME/.config/notchisland/signing-keychain.password"

unlock() {
  [[ -f "$KEYCHAIN" && -f "$PASSFILE" ]] || return 1
  security unlock-keychain -p "$(cat "$PASSFILE")" "$KEYCHAIN" 2>/dev/null
}

has_identity() {
  security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1
}

if [[ "${1:-}" == "--unlock" ]]; then
  unlock && has_identity && print -r -- "$KEYCHAIN"
  exit $?
fi

if unlock && has_identity; then
  echo "✓ identity \"$NAME\" ready in $KEYCHAIN"
  exit 0
fi

[[ -f "$KEYCHAIN" ]] && echo "! existing keychain can't be used (missing password or certificate); replacing it"
echo "▸ creating identity \"$NAME\""
mkdir -p "$(dirname "$PASSFILE")"
chmod 700 "$(dirname "$PASSFILE")"
PASS="$(/usr/bin/openssl rand -hex 24)"
(umask 077; print -r -- "$PASS" > "$PASSFILE")

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
O = NotchIsland
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
  -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -passout "pass:$PASS" -out "$TMP/identity.p12"

rm -f "$KEYCHAIN"
security create-keychain -p "$PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"                                  # never auto-lock
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASS" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KEYCHAIN" >/dev/null
echo "✓ identity \"$NAME\" created in $KEYCHAIN"
echo "  back up that file and $PASSFILE: a different identity makes users re-grant permissions"
