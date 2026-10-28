#!/bin/bash
# Creates a self-signed code-signing certificate named "Vircam Self-Signed" in the login
# keychain and points DEV builds at it (mac/Config/Local.xcconfig).
#
# Ad-hoc builds get a new signature on every build, so macOS treats each update as a new
# app and drops its camera permission. Builds signed with one certificate keep it.
# Release maintainers run this once and keep the keychain item; never commit the key.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="Vircam Self-Signed"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "\"$NAME\" already exists in your keychain."
else
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/cert.cnf" <<CNF
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
CNF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
  PASS="$(uuidgen)"
  /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/cert.p12" -passout "pass:$PASS"
  security import "$TMP/cert.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign
  echo "Created \"$NAME\"."
fi

LOCAL=mac/Config/Local.xcconfig
touch "$LOCAL"
grep -q '^VIRCAM_DEV_IDENTITY' "$LOCAL" || echo "VIRCAM_DEV_IDENTITY = $NAME" >> "$LOCAL"
echo "DEV builds now sign with \"$NAME\"."
