# deps.lock helpers: pinned binaries, fetched and verified into vendor/. Source after
# lib/common.sh; do not execute. Compatible with macOS /bin/bash 3.2.

DEPS_LOCK="${YT4S_DEPS_LOCK:-$REPO_ROOT/deps.lock}"
VENDOR_DIR="${YT4S_VENDOR_DIR:-$REPO_ROOT/vendor}"
DEPS_CACHE="$VENDOR_DIR/cache"
DEP_NAMES="yt-dlp deno ffmpeg ffprobe"

sha256_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}

# lock_field NAME FIELD -> prints version|sha256|url for NAME from deps.lock.
lock_field() {
  local name=$1 field=$2 column
  case $field in
    version) column=2 ;;
    sha256) column=3 ;;
    url) column=4 ;;
    *) die "unknown lock field '$field'" ;;
  esac
  local value
  value=$(awk -v n="$name" -v c="$column" '$1 !~ /^#/ && $1 == n { print $c }' "$DEPS_LOCK")
  [ -n "$value" ] || die "deps.lock has no entry for '$name'"
  echo "$value"
}

# download_verified URL SHA256 DEST: downloads to DEST, aborting (and deleting it) on mismatch.
download_verified() {
  local url=$1 expected=$2 dest=$3 actual
  mkdir -p "$(dirname "$dest")"
  curl --fail --location --silent --show-error --retry 3 --output "$dest.download" "$url" \
    || { rm -f "$dest.download"; die "download failed: $url"; }
  actual=$(sha256_of "$dest.download")
  if [ "$actual" != "$expected" ]; then
    rm -f "$dest.download"
    die "checksum mismatch for $url
  expected $expected
  actual   $actual"
  fi
  mv "$dest.download" "$dest"
}

# fetch_dep NAME: ensures vendor/NAME/ holds the verified, unzipped artifact pinned in deps.lock.
# Archives are cached in vendor/cache/<sha256>.zip; a cached file is re-verified before use.
fetch_dep() {
  local name=$1 version sha url archive target stamp
  version=$(lock_field "$name" version)
  sha=$(lock_field "$name" sha256)
  url=$(lock_field "$name" url)
  archive="$DEPS_CACHE/$sha.zip"
  target="$VENDOR_DIR/$name"
  stamp="$target/.yt4s-sha256"

  if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$sha" ]; then
    echo "$name $version: up to date"
    return
  fi

  if [ -f "$archive" ] && [ "$(sha256_of "$archive")" = "$sha" ]; then
    echo "$name $version: using cached archive"
  else
    rm -f "$archive"
    echo "$name $version: downloading $url"
    download_verified "$url" "$sha" "$archive"
  fi

  rm -rf "$target"
  mkdir -p "$target"
  # ditto keeps symlinks and permissions inside the yt-dlp onedir.
  ditto -x -k "$archive" "$target"
  echo "$sha" > "$stamp"
}
