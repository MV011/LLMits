#!/bin/bash
set -euo pipefail

# Build LLMits as a .app bundle
# Usage: ./build.sh [--release] [--install]

RELEASE=false
INSTALL=false

for arg in "$@"; do
    case $arg in
        --release) RELEASE=true ;;
        --install) INSTALL=true ;;
    esac
done

CONFIG="debug"
if $RELEASE; then
    CONFIG="release"
fi

echo "🔨 Building LLMits ($CONFIG)..."
swift build -c $CONFIG 2>&1

APP_NAME="LLMits"
APP_DIR="$APP_NAME.app"
BINARY=".build/$CONFIG/$APP_NAME"

echo "📦 Creating $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy binary
cp "$BINARY" "$APP_DIR/Contents/MacOS/$APP_NAME"

# Copy Info.plist
cp "Info.plist" "$APP_DIR/Contents/"

# Copy resources (SVGs, etc.) — Swift PM bundles them, but we also want them accessible
if [ -d ".build/$CONFIG/LLMits_LLMits.bundle" ]; then
    cp -R ".build/$CONFIG/LLMits_LLMits.bundle" "$APP_DIR/Contents/Resources/"
fi

# Code-sign with entitlements (seals Info.plist + binary together).
# Prefer the stable self-signed "LLMits Local Signing" identity — it lets macOS
# persist Keychain "Always Allow" grants across rebuilds (ad-hoc signing cannot,
# which is why unsigned builds keep asking for the keychain password).
# Created on demand by scripts/create-signing-identity.sh; no Apple account needed.
SIGNING_IDENTITY="LLMits Local Signing"
if ! security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY"; then
    ./scripts/create-signing-identity.sh || true
fi

echo "🔏 Code-signing $APP_DIR..."
if security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY"; then
    codesign --force --sign "$SIGNING_IDENTITY" \
        --entitlements "LLMits.entitlements" \
        --identifier "com.mv011.llmits" \
        "$APP_DIR"
    echo "   Signed with stable identity '$SIGNING_IDENTITY'"
else
    echo "   ⚠️  '$SIGNING_IDENTITY' unavailable — falling back to ad-hoc signing."
    echo "   ⚠️  Keychain 'Always Allow' grants will NOT persist across rebuilds."
    codesign --force --sign - \
        --entitlements "LLMits.entitlements" \
        --identifier "com.mv011.llmits" \
        "$APP_DIR"
fi

echo "✅ Built $APP_DIR"

if $INSTALL; then
    INSTALL_DIR="/Applications"
    echo "📲 Installing to $INSTALL_DIR..."
    rm -rf "$INSTALL_DIR/$APP_DIR"
    cp -R "$APP_DIR" "$INSTALL_DIR/"
    echo "✅ Installed to $INSTALL_DIR/$APP_DIR"
    echo ""
    echo "Launch with: open /Applications/$APP_DIR"
fi

echo ""
echo "Run with: open $APP_DIR"
echo "Or:       ./$APP_DIR/Contents/MacOS/$APP_NAME"
