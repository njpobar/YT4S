#!/bin/bash
# Builds an ad-hoc signed build/YT4S.app with the pinned yt-dlp, Deno, ffmpeg and ffprobe,
# then runs the post-signing gate. Exits non-zero if any step or gate check fails.
#
# Usage: scripts/build-app.sh
set -euo pipefail
source "$(dirname "$0")/lib/deps.sh"

BUNDLE_ID="com.njpobar.YT4S"
BUILD_DIR="$REPO_ROOT/build"
APP="$BUILD_DIR/YT4S.app"
CONTENTS="$APP/Contents"
BIN="$CONTENTS/Resources/bin"

[ "$(uname -m)" = arm64 ] || die "YT4S is Apple Silicon only; build on an arm64 Mac"

step() { echo "==> $*"; }

# ---- 1. Inputs -------------------------------------------------------------------------------

step "Fetching pinned binaries"
"$REPO_ROOT/scripts/fetch-deps.sh"

version=$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION must be semver X.Y.Z, got '$version'"
# Monotonic build number: commits on the current branch (release.sh only builds from main).
build_number=$(git -C "$REPO_ROOT" rev-list --count HEAD)

step "Compiling YT4S $version ($build_number), release, arm64"
swift build --package-path "$REPO_ROOT" -c release --arch arm64 --product YT4S
products=$(swift build --package-path "$REPO_ROOT" -c release --arch arm64 --show-bin-path)

# ---- 2. Assemble -----------------------------------------------------------------------------

step "Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Frameworks" "$BIN" "$CONTENTS/Resources/Licenses/ffmpeg"

cp "$products/YT4S" "$CONTENTS/MacOS/YT4S"
ditto "$products/Sparkle.framework" "$CONTENTS/Frameworks/Sparkle.framework"

ditto "$VENDOR_DIR/yt-dlp" "$BIN/yt-dlp"
rm -f "$BIN/yt-dlp/.yt4s-sha256"
cp "$VENDOR_DIR/deno/deno" "$VENDOR_DIR/ffmpeg/ffmpeg" "$VENDOR_DIR/ffprobe/ffprobe" "$BIN/"
chmod 755 "$BIN/deno" "$BIN/ffmpeg" "$BIN/ffprobe" "$BIN/yt-dlp/yt-dlp_macos"

# ffmpeg is GPLv3 (--enable-gpl --enable-version3): ship the license and where to get the source.
ffmpeg_version=$(lock_field ffmpeg version)
cp "$REPO_ROOT/third_party/ffmpeg/COPYING.GPLv3" "$CONTENTS/Resources/Licenses/ffmpeg/COPYING.GPLv3"
cat > "$CONTENTS/Resources/Licenses/ffmpeg/SOURCE.txt" <<EOF
YT4S bundles ffmpeg and ffprobe $ffmpeg_version, licensed under the GNU General Public License v3 (see COPYING.GPLv3).

Binaries:     $(lock_field ffmpeg url)
              $(lock_field ffprobe url)
Source code:  https://ffmpeg.org/releases/ffmpeg-$ffmpeg_version.tar.xz
Build script: https://git.martin-riedl.de/ffmpeg/build-script

$("$VENDOR_DIR/ffmpeg/ffmpeg" -hide_banner -version | sed -n '1p;/^configuration:/p')
EOF

cat > "$CONTENTS/Info.plist" <<EOF
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
    <string>$BUNDLE_ID</string>
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
</dict>
</plist>
EOF
plutil -lint "$CONTENTS/Info.plist" > /dev/null

# ---- 3. Ad-hoc sign, inside-out --------------------------------------------------------------
# No Hardened Runtime (-o runtime), no entitlements, no App Sandbox (ADR 0002).

sign() { codesign --force --sign - --timestamp=none "$@"; }

# Upstream's yt-dlp_macos.zip stores _internal/Python.framework with its symlinks flattened into
# copies, which codesign rejects as "bundle format is ambiguous". Restore the standard framework
# layout (Versions/Current and top-level entries as symlinks) so it signs as a real framework.
restore_framework_symlinks() {
  local framework=$1 current entry name
  current=$(find "$framework/Versions" -mindepth 1 -maxdepth 1 -type d ! -name Current | head -1)
  [ -n "$current" ] || die "$framework has no versioned directory"
  rm -rf "$framework/Versions/Current"
  ln -s "$(basename "$current")" "$framework/Versions/Current"
  for entry in "$current"/*; do
    name=$(basename "$entry")
    rm -rf "${framework:?}/$name"
    ln -s "Versions/Current/$name" "$framework/$name"
  done
}

step "Signing yt-dlp onedir binaries"
while IFS= read -r -d '' framework; do
  restore_framework_symlinks "$framework"
done < <(find "$BIN/yt-dlp" -type d -name '*.framework' -print0)
while IFS= read -r -d '' file; do
  if file -b "$file" | grep -q 'Mach-O'; then sign "$file"; fi
done < <(find "$BIN/yt-dlp" -type f ! -path '*.framework/*' -print0)
while IFS= read -r -d '' framework; do
  sign "$framework"
done < <(find "$BIN/yt-dlp" -type d -name '*.framework' -print0)

step "Signing Deno, ffmpeg, ffprobe"
sign "$BIN/deno" "$BIN/ffmpeg" "$BIN/ffprobe"

step "Signing Sparkle helpers"
sparkle="$CONTENTS/Frameworks/Sparkle.framework"
sign "$sparkle/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$sparkle/Versions/B/XPCServices/Downloader.xpc"
sign "$sparkle/Versions/B/Autoupdate"
sign "$sparkle/Versions/B/Updater.app"
sign "$sparkle"

step "Signing YT4S.app"
sign "$APP"

# ---- 4. Post-signing gate --------------------------------------------------------------------

step "Gate: codesign --verify --deep --strict"
codesign --verify --deep --strict --verbose=2 "$APP"

gate_run() {  # gate_run LABEL CMD...: runs CMD from inside the bundle, shows its first line
  local output
  output=$("$@" 2>&1) || die "gate: $1 failed:
$output"
  echo "    $(basename "$1"): $(echo "$output" | head -1)"
}

step "Gate: bundled tools run from inside the app"
gate_run "$BIN/yt-dlp/yt-dlp_macos" --version
gate_run "$BIN/deno" --version
gate_run "$BIN/ffmpeg" -version
gate_run "$BIN/ffprobe" -version

step "Built $APP ($(du -sh "$APP" | cut -f1))"
