# Sparkle (app self-update) settings shared by build-app.sh and release.sh. Source after
# lib/deps.sh; do not execute. Compatible with macOS /bin/bash 3.2.

# The appcast is a release asset; /releases/latest/ only resolves to published (non-draft) releases.
SPARKLE_FEED_URL="${YT4S_FEED_URL:-https://github.com/njpobar/YT4S/releases/latest/download/appcast.xml}"
SPARKLE_PUBLIC_KEY_FILE="$REPO_ROOT/config/sparkle-public-key"

# sparkle_public_key -> the EdDSA public key baked into the app as SUPublicEDKey: YT4S_SPARKLE_PUBLIC_KEY
# (local test builds), else the checked-in config/sparkle-public-key. Empty if neither is set.
sparkle_public_key() {
  if [ -n "${YT4S_SPARKLE_PUBLIC_KEY:-}" ]; then
    echo "$YT4S_SPARKLE_PUBLIC_KEY"
  else
    { grep -v '^#' "$SPARKLE_PUBLIC_KEY_FILE" || true; } | tr -d '[:space:]'
  fi
}

# sparkle_bin -> the directory with Sparkle's sign_update and generate_keys: YT4S_SPARKLE_BIN, else
# the SwiftPM artifact (present once the package is resolved, e.g. after swift test).
sparkle_bin() {
  echo "${YT4S_SPARKLE_BIN:-$REPO_ROOT/.build/artifacts/sparkle/Sparkle/bin}"
}
