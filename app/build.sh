#!/bin/bash
# Build and package Sottovoce.app.
# Usage: app/build.sh [--install]; --install copies it to /Applications and relaunches it.
#
# Signing: signed with a fixed self-signed certificate and a designated requirement of "identifier + certificate
# hash", so the system still sees the same app after a rebuild and Accessibility / microphone permissions stay
# granted. The certificate lives in a dedicated keychain (empty password, not in the keychain search list) that is
# created on first run; deleting that keychain generates a new certificate, and permissions must be granted again.
set -euo pipefail
cd "$(dirname "$0")"

KEYCHAIN="$HOME/Library/Keychains/sottovoce-signing.keychain-db"
IDENTITY="Sottovoce Self-Signed"

ensure_identity() {
  [ -f "$KEYCHAIN" ] || security create-keychain -p "" "$KEYCHAIN"
  security set-keychain-settings "$KEYCHAIN"   # never auto-lock
  security unlock-keychain -p "" "$KEYCHAIN"
  security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1 && return
  echo "Creating self-signed code signing certificate: $IDENTITY"
  local t; t=$(mktemp -d)
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$IDENTITY" \
    -keyout "$t/key.pem" -out "$t/cert.pem" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" 2>/dev/null
  # security can't read OpenSSL 3's default p12 encryption, so use -legacy
  openssl pkcs12 -export -legacy -inkey "$t/key.pem" -in "$t/cert.pem" -out "$t/id.p12" -passout pass:tmp
  security import "$t/id.p12" -k "$KEYCHAIN" -P tmp -T /usr/bin/codesign
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null
  rm -rf "$t"
}

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Sottovoce"

APP=build/Sottovoce.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Sottovoce"
cp Info.plist "$APP/Contents/Info.plist"
# The icon is an Icon Composer document: actool renders Liquid Glass into Assets.car for macOS 26+
# and writes a flat AppIcon.icns for earlier systems
xcrun actool AppIcon.icon --compile "$APP/Contents/Resources" --app-icon AppIcon --platform macosx \
  --minimum-deployment-target 14.0 --target-device mac --output-partial-info-plist "$(mktemp)" >/dev/null
# Localizations (Localizable.strings, InfoPlist.strings)
cp -R Resources/*.lproj "$APP/Contents/Resources/"

ensure_identity
codesign --force --keychain "$KEYCHAIN" --sign "$IDENTITY" --identifier sh.asgard.sottovoce "$APP"
codesign -dr - "$APP" 2>&1 | grep designated
echo "Packaged: $PWD/$APP"

if [ "${1:-}" = "--install" ]; then
  pkill -x Sottovoce || true
  # Wait for the old process to exit, otherwise open fails with -600
  for _ in $(seq 50); do pgrep -x Sottovoce >/dev/null || break; sleep 0.1; done
  sleep 0.5   # LaunchServices needs a moment after the process exits before it accepts a new open
  rm -rf /Applications/Sottovoce.app
  cp -R "$APP" /Applications/
  open /Applications/Sottovoce.app
  echo "Installed and launched: /Applications/Sottovoce.app"
fi
