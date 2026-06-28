#!/bin/bash
# Create a self-signed code-signing certificate for stable local development.
# A stable identity keeps macOS TCC grants (Accessibility, Screen Recording,
# Speech Recognition) valid across rebuilds. Ad-hoc signing changes the binary
# identity on every build, invalidating existing grants.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CERT_DIR="$PROJECT_DIR/.codesign"
KEYCHAIN="$PROJECT_DIR/HermesSigning.keychain-db"
CERT_NAME="${HERMES_CERT_NAME:-Hermes Code Signing}"
P12_PASS="${HERMES_CERT_PASS:-hermes}"

mkdir -p "$CERT_DIR"

if [ -f "$KEYCHAIN" ]; then
    echo "Code-signing keychain already exists: $KEYCHAIN"
    echo "Run 'rm $KEYCHAIN' and rerun if you want to recreate it."
    exit 0
fi

echo "Generating self-signed code-signing certificate: $CERT_NAME"

cat > "$CERT_DIR/hermes.cnf" <<'EOF'
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = Hermes Code Signing

[v3_req]
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
basicConstraints = critical, CA:FALSE
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF

openssl genrsa -out "$CERT_DIR/hermes.key" 2048 >/dev/null 2>&1
openssl req -x509 -new -key "$CERT_DIR/hermes.key" \
    -out "$CERT_DIR/hermes.crt" -days 3650 -config "$CERT_DIR/hermes.cnf" >/dev/null 2>&1

# Export to PKCS#12 using algorithms that macOS security(1) accepts.
if openssl pkcs12 -export -legacy \
    -out "$CERT_DIR/hermes.p12" \
    -inkey "$CERT_DIR/hermes.key" \
    -in "$CERT_DIR/hermes.crt" \
    -password pass:"$P12_PASS" >/dev/null 2>&1; then
    :
else
    openssl pkcs12 -export \
        -out "$CERT_DIR/hermes.p12" \
        -inkey "$CERT_DIR/hermes.key" \
        -in "$CERT_DIR/hermes.crt" \
        -password pass:"$P12_PASS" \
        -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg SHA1 >/dev/null 2>&1
fi

# Create a dedicated keychain with an empty password.
security create-keychain -p "" "$KEYCHAIN"
security unlock-keychain -p "" "$KEYCHAIN"
# Lock after 1h of inactivity; allow codesign access without prompting.
security set-keychain-settings -t 3600 -l "$KEYCHAIN"
security import "$CERT_DIR/hermes.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign

# Make the keychain visible to codesign.
security list-keychains -s "$KEYCHAIN" $(security list-keychains | tr -d '"')

echo ""
echo "Created code-signing identity '$CERT_NAME' in:"
echo "  $KEYCHAIN"
echo ""
echo "The certificate files are in:"
echo "  $CERT_DIR"
echo ""
echo "Run 'make bundle' to sign Hermes.app with this identity."
