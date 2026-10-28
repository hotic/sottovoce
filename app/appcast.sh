#!/bin/bash
# Write and sign the Sparkle feed for a published Release: app/build/appcast.xml, with one item for the Release's DMG.
# Installed apps read it from releases/latest/download/appcast.xml (SUFeedURL in Info.plist), so only the newest
# version needs to be in it.
# Usage: app/appcast.sh <tag> <dmg>, after app/package.sh, with the private EdDSA key in SPARKLE_PRIVATE_KEY and gh
# signed in. The release workflow passes the DMG the Release holds, which may be one an earlier attempt attached.
#
# Both the DMG and the feed are signed with the key whose public half is SUPublicEDKey in Info.plist: the app refuses
# an unsigned or altered feed (SURequireSignedFeed) and checks the DMG before opening it (SUVerifyUpdateBeforeExtraction).
set -euo pipefail
cd "$(dirname "$0")"
TAG=$1
DMG=$2
REPO=${GH_REPO:-hotic/sottovoce}
SIGN=.build/artifacts/sparkle/Sparkle/bin/sign_update
PLIST=build/Sottovoce.app/Contents/Info.plist

if [ -z "${SPARKLE_PRIVATE_KEY:-}" ]; then
  echo "SPARKLE_PRIVATE_KEY is not set" >&2
  exit 1
fi
read_plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST"; }
VERSION=$(read_plist CFBundleVersion)
SHORT=$(read_plist CFBundleShortVersionString)
MINIMUM=$(read_plist LSMinimumSystemVersion)
if [ "$TAG" != "v$SHORT" ]; then
  echo "Tag $TAG doesn't match the app's version $SHORT" >&2
  exit 1
fi
NAME=$(basename "$DMG")

# sparkle:edSignature="..." length="..."
signature=$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN" --ed-key-file - "$DMG")

# The Release's notes, rendered to HTML by GitHub, are the text of the update dialog
work=$(mktemp -d)
gh release view "$TAG" -R "$REPO" --json body --jq .body > "$work/notes.md"
notes=$(gh api markdown -F text=@"$work/notes.md" -f mode=gfm -f context="$REPO")
rm -rf "$work"
notes=${notes//]]>/]]]]><![CDATA[>}
published=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")

cat > build/appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Sottovoce</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>Sottovoce $SHORT</title>
      <pubDate>$published</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$SHORT</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINIMUM</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/$TAG</sparkle:fullReleaseNotesLink>
      <description><![CDATA[$notes]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/$NAME" $signature type="application/octet-stream"/>
    </item>
  </channel>
</rss>
EOF
# Embeds the feed's own signature
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN" --ed-key-file - build/appcast.xml
echo "Wrote $PWD/build/appcast.xml for $NAME"
