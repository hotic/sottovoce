#!/bin/bash
# Package Sottovoce for other Macs: app/build/Sottovoce-<version>.dmg, holding the app beside a link to /Applications.
# The app and the DMG are signed with a Developer ID, notarized and stapled, so a downloaded copy opens without
# Gatekeeper warnings ("damaged" or "unidentified developer"), even offline.
# Usage: app/package.sh (the release workflow runs it on a GitHub-hosted Mac)
#
# Signing: SOTTOVOCE_SIGN_IDENTITY, or else the first "Developer ID Application" identity in the keychain.
# Notarization: an App Store Connect API key (APPLE_API_KEY, APPLE_API_ISSUER, APPLE_API_KEY_PATH; what CI uses) or a
# notarytool keychain profile (SOTTOVOCE_NOTARY_PROFILE, saved once with `xcrun notarytool store-credentials`).
# Without either the DMG is signed but not notarized: good for checking the packaging, refused by other Macs.
set -euo pipefail
cd "$(dirname "$0")"

identity="${SOTTOVOCE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')}"
if [ -z "$identity" ]; then
  echo "No Developer ID Application identity in the keychain" >&2
  exit 1
fi
export SOTTOVOCE_SIGN_IDENTITY="$identity"

auth=()
if [ -n "${APPLE_API_KEY:-}" ] && [ -n "${APPLE_API_ISSUER:-}" ] && [ -n "${APPLE_API_KEY_PATH:-}" ]; then
  auth=(--key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY" --issuer "$APPLE_API_ISSUER")
elif [ -n "${SOTTOVOCE_NOTARY_PROFILE:-}" ]; then
  auth=(--keychain-profile "$SOTTOVOCE_NOTARY_PROFILE")
else
  echo "warning: no notarization credentials; the DMG is signed but not notarized, and other Macs will refuse it" >&2
fi

# notarize <file to submit> <file to staple>: waits for Apple's verdict; on rejection prints Apple's log and stops.
# notarytool exits 0 even for a rejected submission, so the status is read from its JSON
notarize() {
  local result status id
  result=$(xcrun notarytool submit "$1" "${auth[@]}" --wait --output-format json) || true
  status=$(plutil -extract status raw -o - - <<< "$result" 2>/dev/null) || true
  if [ "$status" != "Accepted" ]; then
    echo "Notarization of $1 failed: ${status:-$result}" >&2
    id=$(plutil -extract id raw -o - - <<< "$result" 2>/dev/null) || true
    [ -z "$id" ] || xcrun notarytool log "$id" "${auth[@]}" >&2
    exit 1
  fi
  xcrun stapler staple "$2"
}

./build.sh
APP=build/Sottovoce.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/Sottovoce-$VERSION.dmg"

# The app on its own first: its stapled ticket lets it open offline once copied out of the DMG
if [ ${#auth[@]} -gt 0 ]; then
  ditto -c -k --keepParent "$APP" build/Sottovoce.zip
  notarize build/Sottovoce.zip "$APP"
  rm build/Sottovoce.zip
fi

# LZMA-compressed image (ULMO, macOS 10.15+); Apple asks for the outermost container to be notarized too
stage=$(mktemp -d)
ditto "$APP" "$stage/Sottovoce.app"
ln -s /Applications "$stage/Applications"
rm -f "$DMG"
hdiutil create -volname Sottovoce -srcfolder "$stage" -format ULMO -quiet "$DMG"
rm -rf "$stage"
codesign --force --timestamp --sign "$SOTTOVOCE_SIGN_IDENTITY" "$DMG"
if [ ${#auth[@]} -gt 0 ]; then
  notarize "$DMG" "$DMG"
fi

codesign --verify --deep --strict "$APP"
codesign --verify "$DMG"
if [ ${#auth[@]} -gt 0 ]; then
  # What Gatekeeper checks on a downloaded copy
  spctl --assess --type execute "$APP"
  spctl --assess --type open --context context:primary-signature "$DMG"
  xcrun stapler validate "$DMG"
fi
echo "Packaged: $PWD/$DMG ($(du -h "$DMG" | cut -f1))"
