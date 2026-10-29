#!/bin/bash
# Prints a new deps.lock line for NAME pointing at the latest upstream build.
# Never edits deps.lock: review the output, then paste it in by hand.
#
# The artifact is downloaded and hashed locally, and the hash must match the checksum
# upstream publishes next to it, so a printed pin is always self-verified.
#
# Usage: scripts/update-deps.sh <yt-dlp|deno|ffmpeg|ffprobe>
set -euo pipefail
source "$(dirname "$0")/lib/deps.sh"

[ $# -eq 1 ] || die "usage: $0 <$(echo $DEP_NAMES | tr ' ' '|')>"
name=$1

github_latest_tag() {
  curl --fail --silent --show-error --location "https://api.github.com/repos/$1/releases/latest" \
    | sed -n 's/^  "tag_name": "\(.*\)",$/\1/p'
}

# published_sha URL FILENAME: first hash in a checksum file whose line names FILENAME (or the only hash).
published_sha() {
  curl --fail --silent --show-error --location "$1" \
    | awk -v f="$2" '{ gsub(/^\*/, "", $2) } NF == 1 || $2 == f { print $1; exit }'
}

case $name in
  yt-dlp)
    version=$(github_latest_tag yt-dlp/yt-dlp-nightly-builds)
    base="https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/download/$version"
    url="$base/yt-dlp_macos.zip"
    published=$(published_sha "$base/SHA2-256SUMS" yt-dlp_macos.zip)
    ;;
  deno)
    tag=$(github_latest_tag denoland/deno)
    version=${tag#v}
    url="https://github.com/denoland/deno/releases/download/$tag/deno-aarch64-apple-darwin.zip"
    published=$(published_sha "$url.sha256sum" deno-aarch64-apple-darwin.zip)
    ;;
  ffmpeg|ffprobe)
    # The redirect resolves to a versioned URL like .../arm64/<build-id>_<version>/ffmpeg.zip
    url=$(curl --fail --silent --show-error --output /dev/null --write-out '%{redirect_url}' \
      "https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/$name.zip")
    [ -n "$url" ] || die "could not resolve latest $name release URL"
    build=$(basename "$(dirname "$url")")
    version=${build#*_}
    published=$(published_sha "$url.sha256" "$name.zip")
    ;;
  *)
    die "unknown dependency '$name' (expected one of: $DEP_NAMES)"
    ;;
esac

[ -n "$version" ] || die "could not determine latest $name version"
[ -n "$published" ] || die "upstream publishes no checksum for $url"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
download_verified "$url" "$published" "$scratch/artifact.zip" >&2

current=$(lock_field "$name" version 2>/dev/null || echo none)
echo "# $name: deps.lock has $current, latest is $version (sha256 verified against upstream checksum)" >&2
printf '%-9s %-19s %s  %s\n' "$name" "$version" "$published" "$url"
