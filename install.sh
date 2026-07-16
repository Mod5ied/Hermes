#!/bin/bash
set -e

ZIP_PATH="${1:-Hermes.app.zip}"
INSTALL_DIR="${2:-/Applications}"
APP_PATH="$INSTALL_DIR/Hermes.app"

if [ ! -f "$ZIP_PATH" ]; then
    echo "Error: $ZIP_PATH not found." >&2
    echo "Download Hermes.app.zip from the Releases page and run:" >&2
    echo "  ./install.sh [path-to-zip] [install-dir]" >&2
    exit 1
fi

echo "Installing Hermes.app to $INSTALL_DIR ..."
pkill -9 hermes 2>/dev/null || true
rm -rf "$APP_PATH"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

ditto -x -k "$ZIP_PATH" "$TMP_DIR"

if [ ! -d "$TMP_DIR/Hermes.app" ]; then
    echo "Error: Hermes.app not found inside $ZIP_PATH" >&2
    exit 1
fi

mv "$TMP_DIR/Hermes.app" "$APP_PATH"

echo ""
echo "Removing the Gatekeeper quarantine flag and re-signing locally for this Mac..."
echo "(This only clears the browser-download quarantine attribute; it does not bypass real security controls.)"
xattr -cr "$APP_PATH"
codesign --force --deep --sign - "$APP_PATH"

echo ""
echo "Verifying Gatekeeper assessment:"
spctl -a -vvv "$APP_PATH" 2>&1 || true

echo ""
echo "Installed $APP_PATH"
echo ""
echo "If this is a fresh install or Hermes was ad-hoc signed, reset macOS permissions:"
echo "  tccutil reset Accessibility com.hermes.app"
echo "  tccutil reset ScreenCapture com.hermes.app"
echo "  tccutil reset SpeechRecognition com.hermes.app"
echo "Then launch Hermes from $INSTALL_DIR and grant the prompts."
echo ""

open "$APP_PATH"
