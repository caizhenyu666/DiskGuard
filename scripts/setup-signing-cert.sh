#!/usr/bin/env bash
set -euo pipefail

CERT_NAME="${DISKGUARD_SIGN_IDENTITY:-DiskGuard Local Signing}"
KEYCHAIN_PATH="${HOME}/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning "$KEYCHAIN_PATH" 2>/dev/null | grep -qF "$CERT_NAME"; then
  echo "==> Code signing identity '$CERT_NAME' already exists and is valid:"
  security find-identity -v -p codesigning "$KEYCHAIN_PATH" | grep -F "$CERT_NAME"
  exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

CNF_FILE="$TMP_DIR/codesign.cnf"
KEY_FILE="$TMP_DIR/codesign.key"
CERT_FILE="$TMP_DIR/codesign.crt"
P12_FILE="$TMP_DIR/codesign.p12"
P12_PASS="$(/usr/bin/openssl rand -hex 16)"

cat > "$CNF_FILE" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3_codesign
prompt = no

[dn]
CN = ${CERT_NAME}
O = DiskGuard Local

[v3_codesign]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

echo "==> Generating 10-year local code signing certificate ($CERT_NAME)..."
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$KEY_FILE" \
  -out "$CERT_FILE" \
  -days 3650 \
  -config "$CNF_FILE" 2>/dev/null

/usr/bin/openssl pkcs12 -export \
  -inkey "$KEY_FILE" \
  -in "$CERT_FILE" \
  -out "$P12_FILE" \
  -passout "pass:${P12_PASS}"

echo "==> Importing certificate into login keychain ($KEYCHAIN_PATH)..."
security import "$P12_FILE" -k "$KEYCHAIN_PATH" -P "$P12_PASS" -T /usr/bin/codesign -T /usr/bin/security

echo "==> Marking certificate trusted for code signing..."
security add-trusted-cert -p codeSign -k "$KEYCHAIN_PATH" "$CERT_FILE"

echo "==> Verifying valid code signing identities:"
security find-identity -v -p codesigning "$KEYCHAIN_PATH"
