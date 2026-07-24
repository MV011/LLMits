#!/bin/bash
set -euo pipefail

# Creates a self-signed code-signing certificate ("LLMits Local Signing") in the
# login keychain. No Apple Developer account needed.
#
# Why: an ad-hoc signed app (codesign -s -) has no verifiable identity, so macOS
# cannot persist "Always Allow" grants for Keychain items owned by other apps
# (e.g. "Claude Code-credentials") — it asks for the keychain password instead,
# and the grant breaks on every rebuild (cdhash changes). A stable self-signed
# identity makes "Always Allow" stick across rebuilds with a single click.
#
# Idempotent: exits without changes if the identity already exists.

IDENTITY="LLMits Local Signing"

if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "✅ Signing identity '$IDENTITY' already exists, nothing to do."
    exit 0
fi

echo "🔐 Creating self-signed code-signing identity '$IDENTITY'..."

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no

[ dn ]
CN = $IDENTITY

[ ext ]
# Self-signed certs must be CA:TRUE for macOS to accept them as their own
# trust anchor during codesign identity validation (same shape Keychain
# Access produces via Certificate Assistant).
basicConstraints   = critical, CA:TRUE
keyUsage           = critical, digitalSignature, keyCertSign
extendedKeyUsage   = critical, codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP_DIR/key.pem" \
    -out "$TMP_DIR/cert.pem" \
    -days 3650 \
    -config "$TMP_DIR/openssl.cnf" 2>/dev/null

# OpenSSL 3 defaults to AES PKCS12 algorithms that macOS `security import`
# rejects ("MAC verification failed") — use -legacy and a throwaway password.
openssl pkcs12 -export -legacy \
    -name "$IDENTITY" \
    -inkey "$TMP_DIR/key.pem" \
    -in "$TMP_DIR/cert.pem" \
    -out "$TMP_DIR/identity.p12" \
    -passout pass:llmits-temp 2>/dev/null

# -T /usr/bin/codesign lets codesign use the private key without an ACL prompt.
security import "$TMP_DIR/identity.p12" \
    -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "llmits-temp" \
    -T /usr/bin/codesign >/dev/null

# Self-signed roots are untrusted by default and `find-identity -v -p codesigning`
# filters them out — trust this cert for code signing (user domain, no admin).
security add-trusted-cert -p codeSign \
    -k "$HOME/Library/Keychains/login.keychain-db" \
    "$TMP_DIR/cert.pem"

if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "✅ Created '$IDENTITY' — builds will now be signed with a stable identity."
    echo "   On next launch, click 'Always Allow' once for the Claude keychain item;"
    echo "   macOS will remember it across all future rebuilds (no password)."
else
    echo "⚠️  Certificate imported but identity not found; falling back to ad-hoc signing." >&2
    exit 1
fi
