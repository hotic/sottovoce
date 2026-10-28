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

# The window that opens with the DMG: big icons, the app on the left, an arrow to Applications on the right. The
# layout lives in the volume's .DS_Store, which only Finder writes, so a writable image is laid out through Finder
# and then compressed
stage=$(mktemp -d)
ditto "$APP" "$stage/Sottovoce.app"
ln -s /Applications "$stage/Applications"
mkdir "$stage/.background"
swift dmg-background.swift "$stage/.background"
tiffutil -cathidpicheck "$stage/.background/background.png" "$stage/.background/background@2x.png" \
  -out "$stage/.background/background.tiff" 2>/dev/null
rm "$stage/.background/"*.png
rw=$(mktemp -d)/Sottovoce.dmg
hdiutil create -volname Sottovoce -srcfolder "$stage" -fs HFS+ -format UDRW -quiet "$rw"
rm -rf "$stage"
# Finder addresses the volume by name: with another "Sottovoce" mounted (an earlier DMG left open) it lays out the
# wrong one and the script fails
if [ -e /Volumes/Sottovoce ]; then
  echo "A volume named Sottovoce is mounted; eject it first" >&2
  exit 1
fi
mnt=$(hdiutil attach "$rw" -readwrite -noverify -noautoopen | grep -o '/Volumes/.*$')
# A failed layout must not leave the half-made volume mounted
trap 'hdiutil detach "$mnt" -quiet 2>/dev/null || true' EXIT
# Bounds and positions match dmg-background.swift: a 640 x 400 window, icon centers at y 170
osascript - "$mnt" <<'EOF'
on run {mnt}
  tell application "Finder"
    set d to (POSIX file mnt as alias)
    open d
    set w to container window of d
    set current view of w to icon view
    set toolbar visible of w to false
    set statusbar visible of w to false
    set bounds of w to {200, 120, 840, 520}
    set o to icon view options of w
    set arrangement of o to not arranged
    set icon size of o to 128
    set text size of o to 13
    set background picture of o to file ".background:background.tiff" of d
    set position of item "Sottovoce.app" of d to {170, 170}
    set position of item "Applications" of d to {470, 170}
    update d without registering applications
    delay 2
    close w
  end tell
end run
EOF
# Finder writes .DS_Store on its own schedule
for _ in $(seq 20); do [ -f "$mnt/.DS_Store" ] && break; sleep 0.5; done
rm -rf "$mnt/.fseventsd"
sync
hdiutil detach "$mnt" -quiet
trap - EXIT
# LZMA-compressed image (ULMO, macOS 10.15+); Apple asks for the outermost container to be notarized too
rm -f "$DMG"
hdiutil convert "$rw" -format ULMO -quiet -o "$DMG"
rm -rf "$(dirname "$rw")"
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
