#!/bin/bash
# Packs an app into a compressed, read-only DMG next to an Applications alias, so a first install
# is drag-and-drop. Verifies the image after writing it.
#
# Usage: scripts/make-dmg.sh <path/to/YT4S.app> <out.dmg> [volume name]
set -euo pipefail
source "$(dirname "$0")/lib/deps.sh"

[ $# -ge 2 ] || die "usage: scripts/make-dmg.sh <app> <out.dmg> [volume name]"
app=$1
out=$2
volume=${3:-YT4S}
[ -d "$app" ] || die "no app at $app"

staging=$(mktemp -d "${TMPDIR:-/tmp}/yt4s-dmg.XXXXXX")
trap 'rm -rf "$staging"' EXIT

ditto "$app" "$staging/$(basename "$app")"
ln -s /Applications "$staging/Applications"

mkdir -p "$(dirname "$out")"
rm -f "$out"
hdiutil create -quiet -volname "$volume" -srcfolder "$staging" -fs HFS+ -format UDZO "$out"
hdiutil verify -quiet "$out"
