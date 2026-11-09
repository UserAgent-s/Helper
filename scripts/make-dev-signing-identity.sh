#!/bin/sh
set -eu

IDENTITY="${UA057_SIGNING_IDENTITY:-UserAgent057 Local Dev}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
XCCONFIG="${UA057_SIGNING_XCCONFIG:-$ROOT/Config/DevSigning.local.xcconfig}"
KEYCHAIN="${UA057_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
OPENSSL=/usr/bin/openssl

write_xcconfig() {
    mkdir -p "$(dirname "$XCCONFIG")"
    printf 'UA057_DEV_CODE_SIGN_IDENTITY = %s\n' "$IDENTITY" > "$XCCONFIG"
    echo "Wrote $XCCONFIG"
}

if security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Certificate \"$IDENTITY\" already exists in $KEYCHAIN, keeping it."
    write_xcconfig
    security find-identity -p codesigning "$KEYCHAIN" | grep "\"$IDENTITY\"" || true
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
    -config "$WORK/cert.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
PASSWORD=$("$OPENSSL" rand -hex 16)
"$OPENSSL" pkcs12 -export -name "$IDENTITY" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/identity.p12" -passout "pass:$PASSWORD"

security import "$WORK/identity.p12" -k "$KEYCHAIN" -f pkcs12 -P "$PASSWORD" -T /usr/bin/codesign
echo "Imported \"$IDENTITY\" into $KEYCHAIN"

if [ "${UA057_SKIP_TRUST:-0}" != "1" ]; then
    echo "macOS will ask for your login password to trust this certificate for code signing only."
    security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"
fi

write_xcconfig
security find-identity -p codesigning "$KEYCHAIN" | grep "\"$IDENTITY\"" || true
echo "Done. Rebuild the Debug app; the first launch after this is the last firewall prompt."
