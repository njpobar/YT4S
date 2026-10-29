# Version and build number helpers. Source after lib/deps.sh; do not execute.
# Compatible with macOS /bin/bash 3.2.
#
# VERSION (semver X.Y.Z) is the single source of CFBundleShortVersionString.
# CFBundleVersion is the commit count of the built commit on main: monotonic as long as main is
# never rewritten, which release.sh enforces by requiring the previous release tag as an ancestor.

is_semver() {
  [[ $1 =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

# read_version_file -> the semver in $REPO_ROOT/VERSION, or dies.
read_version_file() {
  local version
  version=$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")
  is_semver "$version" || die "VERSION must be semver X.Y.Z, got '$version'"
  echo "$version"
}

# version_gt A B: true if semver A > semver B.
version_gt() {
  local a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<< "$1"
  IFS=. read -r b1 b2 b3 <<< "$2"
  [ "$a1" -gt "$b1" ] && return 0
  [ "$a1" -lt "$b1" ] && return 1
  [ "$a2" -gt "$b2" ] && return 0
  [ "$a2" -lt "$b2" ] && return 1
  [ "$a3" -gt "$b3" ]
}

# build_number [REV] -> commit count of REV (default HEAD).
build_number() {
  git -C "$REPO_ROOT" rev-list --count "${1:-HEAD}"
}

# latest_release_tag -> highest vX.Y.Z tag in the repo, or nothing.
latest_release_tag() {
  local tag best="" best_version=""
  while IFS= read -r tag; do
    is_semver "${tag#v}" || continue
    if [ -z "$best" ] || version_gt "${tag#v}" "$best_version"; then
      best=$tag
      best_version=${tag#v}
    fi
  done < <(git -C "$REPO_ROOT" tag --list 'v*')
  echo "$best"
}
