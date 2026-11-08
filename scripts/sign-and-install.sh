#!/bin/sh
set -e

IDENTITY="MeetingAssistant Local Dev"
DERIVED_DATA_APP=$(find ~/Library/Developer/Xcode/DerivedData/MeetingAssistant-* -maxdepth 4 -name "MeetingAssistant.app" -path "*Release*" 2>/dev/null | head -1)

if [ -z "$DERIVED_DATA_APP" ]; then
    echo "No Release build found under DerivedData. Build first:"
    echo "  xcodebuild -project MeetingAssistant.xcodeproj -scheme MeetingAssistant -configuration Release build"
    exit 1
fi

echo "Signing $DERIVED_DATA_APP with identity: $IDENTITY"
codesign --force --deep --sign "$IDENTITY" "$DERIVED_DATA_APP"

echo "Installing to /Applications/MeetingAssistant.app"
pkill -f "MeetingAssistant.app/Contents/MacOS/MeetingAssistant" 2>/dev/null || true
sleep 1
rm -rf /Applications/MeetingAssistant.app
cp -R "$DERIVED_DATA_APP" /Applications/MeetingAssistant.app
xattr -dr com.apple.quarantine /Applications/MeetingAssistant.app 2>/dev/null || true

echo "Clearing stale TCC entries (a fresh compile changes the binary hash even with a stable signing identity, so a leftover entry would just be for the old build and would otherwise leave a confusing duplicate row in System Settings)"
tccutil reset ScreenCapture com.local.MeetingAssistant 2>/dev/null || true
tccutil reset Microphone com.local.MeetingAssistant 2>/dev/null || true

echo "Launching"
open /Applications/MeetingAssistant.app

codesign -dvvv /Applications/MeetingAssistant.app 2>&1 | grep -E "Authority|CDHash"
