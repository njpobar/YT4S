#!/bin/bash
# Writes YT4S.app's Info.plist.
#
# Usage: scripts/write-info-plist.sh <out.plist> <version> <build-number>
#   YT4S_SPARKLE_PUBLIC_KEY / YT4S_FEED_URL override the checked-in key and the GitHub feed, for
#   local update tests only (see README "Test an app update locally").
#
# Never add LSFileQuarantineEnabled: in-app updates must stay unquarantined (ADR 0002).
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
source "$(dirname "$0")/lib/sparkle.sh"

[ $# -eq 3 ] || die "usage: scripts/write-info-plist.sh <out.plist> <version> <build-number>"
out=$1 version=$2 build_number=$3
public_key=$(sparkle_public_key)

public_key_entry=""
if [ -n "$public_key" ]; then
  public_key_entry="<key>SUPublicEDKey</key>
    <string>$public_key</string>"
else
  echo "warning: no Sparkle public key in config/sparkle-public-key; this build cannot update itself" >&2
fi

cat > "$out" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>YT4S</string>
    <key>CFBundleExecutable</key>
    <string>YT4S</string>
    <key>CFBundleIdentifier</key>
    <string>com.njpobar.YT4S</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>YT4S</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$version</string>
    <key>CFBundleVersion</key>
    <string>$build_number</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>SUFeedURL</key>
    <string>$SPARKLE_FEED_URL</string>
    $public_key_entry
    <key>SUEnableAutomaticChecks</key>
    <false/>
    <key>SUAutomaticallyUpdate</key>
    <false/>
    <key>SUAllowsAutomaticUpdates</key>
    <false/>
    <key>SUVerifyUpdateBeforeExtraction</key>
    <true/>
</dict>
</plist>
EOF
plutil -lint "$out" > /dev/null
