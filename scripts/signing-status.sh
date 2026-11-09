#!/bin/sh
set -eu

APP="${1:-}"
if [ -z "$APP" ]; then
    APP=$(ls -td ~/Library/Developer/Xcode/DerivedData/UserAgent057-*/Build/Products/Debug/UserAgent057.app build/DerivedData/Build/Products/Debug/UserAgent057.app 2>/dev/null | head -1 || true)
fi
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
    echo "No Debug UserAgent057.app found. Pass the path: scripts/signing-status.sh /path/to/UserAgent057.app"
    exit 1
fi

echo "App: $APP"
codesign -dvv "$APP" 2>&1 | grep -E "^(Authority|Signature|TeamIdentifier)=" || true
codesign -d -r- "$APP" 2>&1 | grep designated || true
if codesign -d -r- "$APP" 2>&1 | grep -q 'designated => cdhash'; then
    echo "Ad-hoc signature: the firewall and Keychain will treat every rebuild as a new app. Run make dev-identity."
fi
echo "Firewall: $(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate)"
/usr/libexec/ApplicationFirewall/socketfilterfw --getappblocked "$APP" 2>&1 || true
