# Helpers every script shares. Source this file first; do not execute it.
# Compatible with macOS /bin/bash 3.2.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# The one place that names this repo on GitHub: release downloads and the Sparkle feed live there.
GITHUB_REPO_URL="https://github.com/njpobar/YT4S"

die() {
  echo "error: $*" >&2
  exit 1
}

step() {
  echo "==> $*"
}
