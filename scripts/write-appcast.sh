#!/bin/bash
# EdDSA-signs an app zip with Sparkle's sign_update and writes a single-entry appcast for it.
# One entry, no deltas: every update is the full zip (ADR 0002).
#
# Usage: scripts/write-appcast.sh <app.zip> <version> <build-number> <download-url> <out.xml>
#
# sign_update reads the private key from the login Keychain. YT4S_SPARKLE_BIN overrides where
# sign_update lives (tests and local update checks point it at a wrapper using a throwaway key).
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
source "$(dirname "$0")/lib/sparkle.sh"

[ $# -eq 5 ] || die "usage: scripts/write-appcast.sh <app.zip> <version> <build-number> <download-url> <out.xml>"
zip=$1 version=$2 build_number=$3 url=$4 out=$5
[ -f "$zip" ] || die "no such zip: $zip"

# sign_update prints: sparkle:edSignature="<base64>" length="<bytes>"
enclosure_attributes=$("$(sparkle_bin)/sign_update" "$zip") || die "sign_update failed for $zip"
[[ $enclosure_attributes =~ ^sparkle:edSignature=\"[A-Za-z0-9+/=]+\"\ length=\"[0-9]+\"$ ]] \
  || die "unexpected sign_update output: $enclosure_attributes"

pub_date=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')

cat > "$out" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>YT4S</title>
    <item>
      <title>YT4S $version</title>
      <pubDate>$pub_date</pubDate>
      <sparkle:version>$build_number</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="$url" type="application/octet-stream" $enclosure_attributes/>
    </item>
  </channel>
</rss>
EOF
xmllint --noout "$out"
