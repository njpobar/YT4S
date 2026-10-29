#!/bin/bash
# Releases YT4S as a draft GitHub Release. Nothing reaches users until Nick publishes the draft.
#
# Usage: scripts/release.sh [--dry-run] <version>
#
#   1. Preflight: semver newer than the last release, clean tree on main, in sync with origin.
#   2. Gates: swift test, build + sign + post-signing smoke gate, then the live contract test
#      against the yt-dlp + ffmpeg inside the built app (downloads one video from YouTube).
#   3. Package: dist/YT4S-<version>.zip, its EdDSA-signed dist/appcast.xml, dist/YT4S-<version>.dmg.
#   4. Manual checklist: Nick confirms by typing the version.
#   5. Publish: commit the VERSION bump (if any), tag v<version>, push main + tag atomically,
#      gh release create --draft with the assets.
#
# --dry-run runs 1 to 3 and prints what 4 and 5 would do, without touching git or GitHub.
set -euo pipefail
# Only the contract gate below runs live tests, against the app this run builds.
unset YT4S_LIVE_APP
source "$(dirname "$0")/lib/deps.sh"
source "$(dirname "$0")/lib/version.sh"
source "$(dirname "$0")/lib/sparkle.sh"

APP="$REPO_ROOT/build/YT4S.app"
DIST_DIR="$REPO_ROOT/dist"

step() { echo "==> $*"; }
usage() { die "usage: scripts/release.sh [--dry-run] <version>"; }

dry_run=false
version=""
for arg in "$@"; do
  case $arg in
    --dry-run) dry_run=true ;;
    -*) usage ;;
    *) [ -z "$version" ] || usage; version=$arg ;;
  esac
done
[ -n "$version" ] || usage
is_semver "$version" || die "version must be semver X.Y.Z, got '$version'"
tag="v$version"
cd "$REPO_ROOT"

# ---- 1. Preflight ----------------------------------------------------------------------------

step "Preflight"
branch=$(git symbolic-ref --short -q HEAD || true)
[ "$branch" = main ] || die "releases are cut from main, not '${branch:-detached HEAD}'"
[ -z "$(git status --porcelain --untracked-files=all)" ] \
  || die "working tree is not clean:
$(git status --short --untracked-files=all)"
git fetch --quiet --tags origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
  || die "main is not in sync with origin/main; pull or push first"
! git rev-parse -q --verify "refs/tags/$tag" > /dev/null || die "tag $tag already exists"

previous=$(latest_release_tag)
if [ -n "$previous" ]; then
  version_gt "$version" "${previous#v}" || die "$version is not newer than the last release $previous"
  # Build numbers are commit counts on main; they only grow if main was never rewritten.
  git merge-base --is-ancestor "$previous" HEAD || die "$previous is not an ancestor of main"
fi

current=$(read_version_file)
if [ "$current" = "$version" ]; then
  bump=false
  build=$(build_number)
else
  version_gt "$version" "$current" || die "$version is older than VERSION ($current)"
  bump=true
  build=$(( $(build_number) + 1 ))  # the VERSION bump commit is the one that gets tagged
fi
$dry_run || gh auth status > /dev/null 2>&1 || die "gh is not signed in; run: gh auth login"
echo "    YT4S $version, build $build, previous release ${previous:-none}"

# The zip must be signed by the private half of the key the app trusts, or every installed copy
# rejects the update. Checked before the slow gates.
step "Sparkle signing key"
public_key=$(sparkle_public_key)
[ -n "$public_key" ] || die "config/sparkle-public-key is empty; do the one-time setup in README.md (Signing key for app updates)"
[ -x "$(sparkle_bin)/generate_keys" ] || swift package --package-path "$REPO_ROOT" resolve
keychain_key=$("$(sparkle_bin)/generate_keys" -p 2> /dev/null) \
  || die "no Sparkle signing key in your login Keychain; do the one-time setup in README.md (Signing key for app updates)"
[ "$keychain_key" = "$public_key" ] \
  || die "the Sparkle key in your login Keychain ($keychain_key) does not match config/sparkle-public-key ($public_key)"
echo "    login Keychain key matches config/sparkle-public-key"

# ---- 2. Gates --------------------------------------------------------------------------------

step "Gate: swift test"
swift test --package-path "$REPO_ROOT"

step "Build, sign, post-signing smoke gate"
YT4S_VERSION=$version YT4S_BUILD_NUMBER=$build "$REPO_ROOT/scripts/build-app.sh"

plist="$APP/Contents/Info.plist"
built_version=$(plutil -extract CFBundleShortVersionString raw "$plist")
built_build=$(plutil -extract CFBundleVersion raw "$plist")
[ "$built_version" = "$version" ] && [ "$built_build" = "$build" ] \
  || die "built app is $built_version ($built_build), expected $version ($build)"

# The exact yt-dlp + ffmpeg being shipped still honor the contract the app relies on
# (Tests/YT4SCoreTests/LiveContractTests.swift): one real Video and MP3 download.
step "Gate: live contract test against the built app"
contract_report="$REPO_ROOT/build/live-contract-tests.xml"
rm -f "$contract_report"
YT4S_LIVE_APP=$APP swift test --package-path "$REPO_ROOT" --filter "^YT4SCoreTests\.LiveContractTests/" --xunit-output "$contract_report" \
  || die "live contract test failed; the bundled yt-dlp or ffmpeg no longer does what YT4S expects"
# A renamed suite or a skip passes with nothing run; the gate only counts if every test ran.
ran=$(xmllint --xpath 'count(//testcase[not(skipped)])' "$contract_report" 2> /dev/null || echo 0)
skipped=$(xmllint --xpath 'count(//testcase[skipped])' "$contract_report" 2> /dev/null || echo 0)
[ "$ran" -gt 0 ] && [ "$skipped" = 0 ] \
  || die "live contract test did not run (ran $ran, skipped $skipped); see $contract_report"
echo "    $ran live contract tests passed"

# ---- 3. Package ------------------------------------------------------------------------------

zip="$DIST_DIR/YT4S-$version.zip"
dmg="$DIST_DIR/YT4S-$version.dmg"
mkdir -p "$DIST_DIR"
rm -rf "$DIST_DIR/YT4S-$version".* "$DIST_DIR/appcast.xml"

step "Zipping $(basename "$zip")"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$zip"
assets=("$zip")

# EdDSA-signed with the login Keychain key; the app reads the feed at
# releases/latest/download/appcast.xml, so it sees this entry only once the draft is published.
step "Sparkle signature and appcast.xml"
"$REPO_ROOT/scripts/write-appcast.sh" "$zip" "$version" "$build" \
  "https://github.com/njpobar/YT4S/releases/download/$tag/$(basename "$zip")" "$DIST_DIR/appcast.xml"
assets+=("$DIST_DIR/appcast.xml")

step "Making $(basename "$dmg")"
"$REPO_ROOT/scripts/make-dmg.sh" "$APP" "$dmg" "YT4S $version"
assets+=("$dmg")

# ---- 4. Manual checklist ---------------------------------------------------------------------

publish_commands() {
  if $bump; then
    echo "    echo $version > VERSION && git commit -m 'Release $version' VERSION"
  fi
  echo "    git tag -a $tag -m 'YT4S $version'"
  echo "    git push --atomic origin main refs/tags/$tag"
  echo "    gh release create $tag --draft --verify-tag --title 'YT4S $version' ${assets[*]}"
}

if $dry_run; then
  step "Dry run: built ${assets[*]}"
  echo "    Would ask for the manual checklist, then run:"
  publish_commands
  exit 0
fi

cat >&2 <<EOF

==> Manual checklist for YT4S $version, using:
      $dmg
      $zip
    [ ] Fresh install from the DMG on a Mac without YT4S, then Open Anyway in System Settings
    [ ] App update from the previous release (${previous:-none}) to this one
    [ ] yt-dlp update, then rollback
    [ ] Playlist and channel runs, with Cancel and Retry

EOF
printf 'Type %s to confirm every item passed: ' "$version" >&2
answer=""
read -r answer || true
[ "$answer" = "$version" ] || die "not confirmed; nothing was tagged or published"

# ---- 5. Publish ------------------------------------------------------------------------------

step "Tagging $tag"
if $bump; then
  echo "$version" > VERSION
  git commit --quiet -m "Release $version" VERSION
fi
git tag -a "$tag" -m "YT4S $version"
git push --quiet --atomic origin main "refs/tags/$tag"

step "Creating draft release $tag"
gh release create "$tag" --draft --verify-tag --title "YT4S $version" \
  --notes "First install: open YT4S-$version.dmg, drag YT4S to Applications, then Open Anyway (see README). Existing users: click Update app." \
  "${assets[@]}" \
  || die "gh release create failed after $tag was pushed; fix and re-run:
$(publish_commands | tail -1)"

step "Draft release $tag created. Review it on GitHub, then publish it to ship."
