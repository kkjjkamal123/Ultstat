#!/bin/zsh
# Builds Ultstat (Release) and packages it as a compressed DMG.
#   tools/make-dmg.sh                    ad-hoc signed (users right-click › Open on first launch)
#   SIGN_ID="Developer ID Application: …" NOTARY_PROFILE=ultstat tools/make-dmg.sh
#                                        Developer ID signed, notarized and stapled
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_ID=${SIGN_ID:--}
xcodegen generate >/dev/null
xcodebuild -project Ultstat.xcodeproj -scheme Ultstat -configuration Release -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY="$SIGN_ID" OTHER_CODE_SIGN_FLAGS="--timestamp" build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

APP=build/DerivedData/Build/Products/Release/Ultstat.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
codesign --verify --deep --strict "$APP"
echo "signature OK ($(codesign -dv "$APP" 2>&1 | grep -E '^Authority|^Signature' | head -1))"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir -p dist
DMG="dist/Ultstat-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Ultstat $VERSION" -srcfolder "$STAGE" -fs APFS -format ULMO -quiet "$DMG"

if [[ "$SIGN_ID" != "-" && -n "${NOTARY_PROFILE:-}" ]]; then
  codesign --sign "$SIGN_ID" --timestamp "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

shasum -a 256 "$DMG"
ls -lh "$DMG"
