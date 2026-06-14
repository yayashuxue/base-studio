#!/usr/bin/env bash
# Creates (once) a self-signed code-signing certificate in the user's login
# keychain so every rebuild signs with the same identity. macOS TCC then
# recognizes rebuilds as the same app and keeps granted permissions across
# builds — instead of re-prompting on every CDHash change with ad-hoc signing.
#
# Idempotent: if the cert already exists, exits 0 with a no-op.
#
# Usage: ./scripts/setup-dev-cert.sh
set -euo pipefail

CERT_NAME="Base Studio Dev"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

# Use find-identity WITHOUT `-v`: the cert is self-signed and therefore
# untrusted, so `-v` (valid-only) never lists it and the script would re-import
# a duplicate on every run. Matching all codesigning identities keeps this
# genuinely idempotent.
if security find-identity -p codesigning "${KEYCHAIN}" 2>/dev/null \
        | grep -q "\"${CERT_NAME}\""; then
    echo "✓ Cert '${CERT_NAME}' already exists in login keychain — nothing to do."
    exit 0
fi

echo "→ Generating self-signed code-signing cert '${CERT_NAME}' …"
TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT

cat > "${TMP}/cs.cnf" <<EOF
[req]
distinguished_name = req_distinguished_name
prompt = no
[req_distinguished_name]
CN = ${CERT_NAME}
[v3_codesign]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

# Key + self-signed cert with codeSigning EKU.
openssl req -new -newkey rsa:2048 -nodes \
    -keyout "${TMP}/key.pem" -out "${TMP}/req.csr" \
    -config "${TMP}/cs.cnf"

openssl x509 -req -days 3650 \
    -in "${TMP}/req.csr" -signkey "${TMP}/key.pem" \
    -out "${TMP}/cert.pem" \
    -extfile "${TMP}/cs.cnf" -extensions v3_codesign

# Bundle key + cert into PKCS12 with a known password. Use the legacy format
# so older macOS `security` understands the MAC.
P12_PASS="basestudio"
openssl pkcs12 -export -legacy \
    -inkey "${TMP}/key.pem" -in "${TMP}/cert.pem" \
    -name "${CERT_NAME}" \
    -out "${TMP}/cert.p12" -password "pass:${P12_PASS}"

# Import into the login keychain. -A allows codesign to use it without prompting.
security import "${TMP}/cert.p12" \
    -k "${KEYCHAIN}" \
    -P "${P12_PASS}" \
    -T /usr/bin/codesign \
    -A

echo "✓ Imported '${CERT_NAME}' into login keychain."
echo ""
echo "Current code signing identities:"
security find-identity -v -p codesigning "${KEYCHAIN}"
