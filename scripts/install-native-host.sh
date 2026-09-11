#!/bin/bash
set -euo pipefail

HOST_NAME="com.hermes.app"
CHROME_EXTENSION_ID="${1:-jckcedeldkbfekgpnknlabjencclcfpc}"
HOST_BINARY="${2:-/Applications/Hermes.app/Contents/MacOS/hermes}"
MANIFEST_ROOT="${HERMES_NATIVE_MANIFEST_ROOT:-}"

if [[ ! "$CHROME_EXTENSION_ID" =~ ^[a-p]{32}$ ]]; then
    echo "Invalid Chrome/Edge extension ID: $CHROME_EXTENSION_ID" >&2
    exit 1
fi
if [[ ! -x "$HOST_BINARY" ]]; then
    echo "Hermes native host is not executable: $HOST_BINARY" >&2
    exit 1
fi

install_chromium_manifest() {
    local directory="$1"
    mkdir -p "$directory"
    cat > "$directory/$HOST_NAME.json" <<EOF
{
  "name": "$HOST_NAME",
  "description": "Hermes capture-protected desktop companion",
  "path": "$HOST_BINARY",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$CHROME_EXTENSION_ID/"]
}
EOF
}

install_firefox_manifest() {
    local directory="$1"
    mkdir -p "$directory"
    cat > "$directory/$HOST_NAME.json" <<EOF
{
  "name": "$HOST_NAME",
  "description": "Hermes capture-protected desktop companion",
  "path": "$HOST_BINARY",
  "type": "stdio",
  "allowed_extensions": ["hermes@project-hermes.dev"]
}
EOF
}

if [[ -n "$MANIFEST_ROOT" ]]; then
    install_chromium_manifest "$MANIFEST_ROOT/Google/Chrome/NativeMessagingHosts"
    install_chromium_manifest "$MANIFEST_ROOT/Microsoft Edge/NativeMessagingHosts"
    install_chromium_manifest "$MANIFEST_ROOT/Chromium/NativeMessagingHosts"
    install_firefox_manifest "$MANIFEST_ROOT/Mozilla/NativeMessagingHosts"
else
    install_chromium_manifest "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
    install_chromium_manifest "$HOME/Library/Application Support/Microsoft Edge/NativeMessagingHosts"
    install_chromium_manifest "$HOME/Library/Application Support/Chromium/NativeMessagingHosts"
    install_firefox_manifest "$HOME/Library/Application Support/Mozilla/NativeMessagingHosts"
fi

echo "Registered $HOST_NAME for extension $CHROME_EXTENSION_ID"
