#!/bin/bash
# Builds Ultstat (Release), signs it with a local self-signed identity and installs it to
# /Applications.
#
# Why: builds from source are otherwise ad-hoc signed, so every build has a new code hash and the
# root charge helper (which only trusts the exact app it was installed for) needs a fresh
# administrator approval after each update. Signed with a stable local certificate, the helper is
# pinned to that certificate instead, so updates keep working after one approval.
#
# The identity lives in its own keychain (~/Library/Keychains/ultstat-local-signing.keychain-db),
# not the login keychain. The helper only accepts charge-control commands, so this key can't be
# used for anything beyond battery settings. Delete that keychain file to remove it.
set -euo pipefail
cd "$(dirname "$0")/.."

KC="$HOME/Library/Keychains/ultstat-local-signing.keychain-db"
ID="Ultstat Local Signing"
PASS="ultstat-local-signing"

if [ ! -f "$KC" ]; then
    echo "Creating local signing identity…"
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    openssl req -x509 -newkey rsa:2048 -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -days 3650 -nodes -subj "/CN=$ID" \
        -addext "extendedKeyUsage=critical,codeSigning" -addext "keyUsage=critical,digitalSignature" \
        -addext "basicConstraints=critical,CA:false" 2>/dev/null
    openssl pkcs12 -export -legacy -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/id.p12" -passout pass:p 2>/dev/null
    security create-keychain -p "$PASS" "$KC"
    security set-keychain-settings "$KC"            # no auto-lock
    security unlock-keychain -p "$PASS" "$KC"
    security import "$tmp/id.p12" -k "$KC" -P p -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple: -s -k "$PASS" "$KC" >/dev/null
fi
security unlock-keychain -p "$PASS" "$KC"

xcodegen generate >/dev/null
xcodebuild -project Ultstat.xcodeproj -scheme Ultstat -configuration Release -derivedDataPath build/DerivedData build -quiet
APP=build/DerivedData/Build/Products/Release/Ultstat.app

# Re-signs one piece of code with the local identity, keeping its entitlements but never
# get-task-allow (it lets other processes attach to the app, which the root helper trusts).
sign() {
    local ent
    ent=$(mktemp)
    codesign -d --entitlements - --xml "$1" >"$ent" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Delete :com.apple.security.get-task-allow" "$ent" >/dev/null 2>&1 || true
    local args=(--force --sign "$ID" --keychain "$KC" --options runtime --timestamp=none -i "$2")
    if [ -s "$ent" ]; then args+=(--entitlements "$ent"); fi
    codesign "${args[@]}" "$1"
    rm -f "$ent"
}
sign "$APP/Contents/MacOS/io.github.kkjjkamal23.Ultstat.Helper" io.github.kkjjkamal23.Ultstat.Helper
sign "$APP" io.github.kkjjkamal23.Ultstat
codesign --verify --strict "$APP"

pkill -x Ultstat 2>/dev/null || true
sleep 1
rm -rf /Applications/Ultstat.app
cp -R "$APP" /Applications/
open /Applications/Ultstat.app
echo "Installed /Applications/Ultstat.app (signed: $ID)"
