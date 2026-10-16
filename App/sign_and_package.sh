#!/bin/sh
# Signs MacShade.app with a Developer ID, builds MacShade-<version>.dmg, signs it and (if a notarytool keychain profile exists) notarizes and staples it.
#   ./sign_and_package.sh                       -> uses the first "Developer ID Application" identity
#   IDENTITY="Developer ID Application: …" NOTARY_PROFILE=MacShade ./sign_and_package.sh
# One-time setup of the profile (asks for an app-specific password, never stored in this repo):
#   xcrun notarytool store-credentials MacShade --apple-id <apple-id> --team-id <team-id>
set -e; cd "$(dirname "$0")"
IDENTITY=${IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}
PROFILE=${NOTARY_PROFILE:-MacShade}
[ -n "$IDENTITY" ] || { echo "no Developer ID Application identity in the keychain" >&2; exit 1; }
A=MacShade.app; [ -d "$A" ] || ./build_app.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$A/Contents/Info.plist")
DMG=MacShade-$VERSION.dmg

echo "signing with: $IDENTITY"
for f in "$A"/Contents/Resources/*.dylib; do codesign --force --timestamp --options runtime -s "$IDENTITY" "$f"; done
codesign --force --timestamp --options runtime -s "$IDENTITY" "$A"
codesign --verify --deep --strict --verbose=2 "$A"

rm -rf dmg-staging "$DMG"; mkdir dmg-staging
ditto "$A" "dmg-staging/$A"; ln -s /Applications dmg-staging/Applications
hdiutil create -volname "MacShade $VERSION" -srcfolder dmg-staging -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf dmg-staging
codesign --force --timestamp -s "$IDENTITY" "$DMG"

if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl -a -t open --context context:primary-signature -vv "$DMG"
else
  echo "NOT notarized: no notarytool keychain profile '$PROFILE'. Run store-credentials (see top of this script), then:" >&2
  echo "  xcrun notarytool submit $DMG --keychain-profile $PROFILE --wait && xcrun stapler staple $DMG" >&2
fi
echo "built $PWD/$DMG"
