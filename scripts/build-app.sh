#!/bin/bash
# Builds an ad-hoc signed build/YT4S.app with the pinned yt-dlp, Deno, ffmpeg and ffprobe,
# then runs the post-signing gate. Exits non-zero if any step or gate check fails.
#
# Usage: scripts/build-app.sh
#   YT4S_VERSION / YT4S_BUILD_NUMBER override VERSION and the commit count (release.sh sets both).
#   YT4S_SPARKLE_PUBLIC_KEY / YT4S_FEED_URL: local update tests only (see write-info-plist.sh).
set -euo pipefail
source "$(dirname "$0")/lib/deps.sh"
source "$(dirname "$0")/lib/version.sh"

BUILD_DIR="$REPO_ROOT/build"
APP="$BUILD_DIR/YT4S.app"
CONTENTS="$APP/Contents"
BIN="$CONTENTS/Resources/bin"

[ "$(uname -m)" = arm64 ] || die "YT4S is Apple Silicon only; build on an arm64 Mac"

step() { echo "==> $*"; }

# ---- 1. Inputs -------------------------------------------------------------------------------

step "Fetching pinned binaries"
"$REPO_ROOT/scripts/fetch-deps.sh"

# release.sh passes both explicitly (it builds before committing the VERSION bump it tags).
version=${YT4S_VERSION:-$(read_version_file)}
is_semver "$version" || die "version must be semver X.Y.Z, got '$version'"
# Monotonic build number: commit count on main (see scripts/lib/version.sh).
build_number=${YT4S_BUILD_NUMBER:-$(build_number)}
[[ $build_number =~ ^[1-9][0-9]*$ ]] || die "build number must be a positive integer, got '$build_number'"

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
# The bundled floor's tag: the app compares it with downloaded copies (BundledYtDlp, ADR 0002).
lock_field yt-dlp version > "$BIN/yt-dlp-version"

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

"$REPO_ROOT/scripts/write-info-plist.sh" "$CONTENTS/Info.plist" "$version" "$build_number"

# ---- 3. Slim down ----------------------------------------------------------------------------
# YT4S runs on Apple Silicon only, so the x86_64 halves of universal binaries (the yt-dlp onedir,
# Sparkle) are dead weight. Each slice carries its own signature; everything is re-signed below.

step "Thinning universal binaries to arm64"
while IFS= read -r -d '' file; do
  if file -b "$file" | grep -q 'universal binary'; then
    lipo -thin arm64 "$file" -output "$file.arm64"
    chmod "$(stat -f '%Lp' "$file")" "$file.arm64"
    mv "$file.arm64" "$file"
  fi
done < <(find "$APP" -type f -print0)

# Local symbols only; ffmpeg and ffprobe are fully static, so nothing looks them up at run time.
strip "$BIN/ffmpeg" "$BIN/ffprobe" 2> /dev/null

# ---- 4. Ad-hoc sign, inside-out --------------------------------------------------------------
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
# PyInstaller's _internal/Python is a symlink to the framework's binary; the zip made it a copy.
internal="$BIN/yt-dlp/_internal"
if [ -f "$internal/Python" ] && [ ! -L "$internal/Python" ] \
  && cmp -s "$internal/Python" "$internal/Python.framework/Versions/Current/Python"; then
  rm "$internal/Python"
  ln -s Python.framework/Versions/Current/Python "$internal/Python"
fi
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

# ---- 5. Post-signing gate --------------------------------------------------------------------

step "Gate: codesign --verify --deep --strict"
codesign --verify --deep --strict --verbose=2 "$APP"

step "Gate: every binary is arm64 only"
while IFS= read -r -d '' file; do
  if file -b "$file" | grep -q 'Mach-O'; then
    [ "$(lipo -archs "$file")" = arm64 ] || die "gate: $file is $(lipo -archs "$file"), not arm64 only"
  fi
done < <(find "$APP" -type f -print0)

gate_run() {  # gate_run LABEL CMD...: runs CMD from inside the bundle, shows its first line
  local output
  output=$("$@" 2>&1) || die "gate: $1 failed:
$output"
  echo "    $(basename "$1"): $(echo "$output" | head -1)"
}

step "Gate: bundled tools run from inside the app"
gate_run "$BIN/yt-dlp/yt-dlp_macos" --version
bundled_tag=$("$BIN/yt-dlp/yt-dlp_macos" --version)
[ "$bundled_tag" = "$(cat "$BIN/yt-dlp-version")" ] \
  || die "gate: bundled yt-dlp reports $bundled_tag but bin/yt-dlp-version says $(cat "$BIN/yt-dlp-version")"
gate_run "$BIN/deno" --version
gate_run "$BIN/ffmpeg" -version
gate_run "$BIN/ffprobe" -version

step "Built $APP ($(du -sh "$APP" | cut -f1))"
