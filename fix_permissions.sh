#!/bin/bash
set -e

echo "=== Hermes Permission Helper ==="
echo ""
echo "The Speech Recognition pane is empty because Hermes has not yet triggered"
echo "the system speech-authorization dialog. macOS only shows apps in that list"
echo "after they have requested authorization at least once."
echo ""
echo "To force the dialog to appear, we will trigger the authorization request"
echo "using a small helper."
echo ""

# Build a tiny helper that requests speech authorization.
HELPER=$(mktemp /tmp/hermes_speech_helper.XXXXXX)
cat > "$HELPER" <<'SWIFTCODE'
import Foundation
import Speech

if #available(macOS 26.0, *) {
    print("macOS 26+ detected. Checking SpeechTranscriber availability...")
    print("SpeechTranscriber.isAvailable = \(SpeechTranscriber.isAvailable)")
}

SFSpeechRecognizer.requestAuthorization { status in
    switch status {
    case .authorized:
        print("Speech Recognition: AUTHORIZED")
    case .denied:
        print("Speech Recognition: DENIED")
    case .restricted:
        print("Speech Recognition: RESTRICTED")
    case .notDetermined:
        print("Speech Recognition: NOT DETERMINED")
    @unknown default:
        print("Speech Recognition: UNKNOWN")
    }
    CFRunLoopStop(CFRunLoopGetCurrent())
}
CFRunLoopRun()
SWIFTCODE

echo "Compiling helper..."
swiftc -target arm64-apple-macosx26.0 -o /tmp/hermes_speech_auth "$HELPER" 2>/dev/null || {
    echo "swiftc failed, trying with xcrun..."
    xcrun swiftc -target arm64-apple-macosx26.0 -o /tmp/hermes_speech_auth "$HELPER"
}
rm -f "$HELPER"

echo ""
echo "Running helper to trigger the authorization dialog..."
echo "(Look for a system dialog asking for Speech Recognition permission)"
echo ""
/tmp/hermes_speech_auth

echo ""
echo "Done. Now open System Settings and check Speech Recognition again."
echo "Hermes should appear in the list."
echo ""
echo "If you want to grant all three permissions via command line, run:"
echo ""
echo "  tccutil reset SpeechRecognition"
echo "  tccutil reset ScreenCapture"
echo "  tccutil reset Accessibility"
echo ""
echo "Then relaunch Hermes to trigger the dialogs again."
