#!/bin/bash
set -e

pkill -9 hermes 2>/dev/null || true
rm -rf /Applications/Hermes.app
cp -R /Users/mac/Documents/Hermes/Hermes.app /Applications/
xattr -dr com.apple.quarantine /Applications/Hermes.app

echo "Installed /Applications/Hermes.app"
echo ""
echo "If this is a fresh build or Hermes was ad-hoc signed, reset macOS permissions:"
echo "  tccutil reset Accessibility com.hermes.app"
echo "  tccutil reset ScreenCapture com.hermes.app"
echo "  tccutil reset SpeechRecognition com.hermes.app"
echo "Then launch Hermes from /Applications and grant the prompts."
echo ""

open /Applications/Hermes.app
