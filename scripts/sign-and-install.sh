#!/bin/sh
set -e

IDENTITY="UserAgent057 Local Dev"
DERIVED_DATA_APP=$(find ~/Library/Developer/Xcode/DerivedData/UserAgent057-* -maxdepth 4 -name "UserAgent057.app" -path "*Release*" 2>/dev/null | head -1)

if [ -z "$DERIVED_DATA_APP" ]; then
    echo "No Release build found under DerivedData. Build first:"
    echo "  xcodebuild -project UserAgent057.xcodeproj -scheme UserAgent057 -configuration Release build"
    exit 1
fi

echo "Signing $DERIVED_DATA_APP with identity: $IDENTITY"
codesign --force --deep --sign "$IDENTITY" "$DERIVED_DATA_APP"

echo "Installing to /Applications/UserAgent057.app"
pkill -f "UserAgent057.app/Contents/MacOS/UserAgent057" 2>/dev/null || true
sleep 1
rm -rf /Applications/UserAgent057.app
cp -R "$DERIVED_DATA_APP" /Applications/UserAgent057.app
xattr -dr com.apple.quarantine /Applications/UserAgent057.app 2>/dev/null || true

echo "Clearing stale TCC entries (a fresh compile changes the binary hash even with a stable signing identity, so a leftover entry would just be for the old build and would otherwise leave a confusing duplicate row in System Settings)"
tccutil reset ScreenCapture com.local.UserAgent057 2>/dev/null || true
tccutil reset Microphone com.local.UserAgent057 2>/dev/null || true

echo "Launching"
open /Applications/UserAgent057.app

codesign -dvvv /Applications/UserAgent057.app 2>&1 | grep -E "Authority|CDHash"
