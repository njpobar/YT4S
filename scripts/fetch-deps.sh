#!/bin/bash
# Fetches every binary pinned in deps.lock into vendor/, verifying SHA-256.
# Usage: scripts/fetch-deps.sh [name...]   (default: all)
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
source "$(dirname "$0")/lib/deps.sh"

names=${*:-$DEP_NAMES}
for name in $names; do
  fetch_dep "$name"
done
