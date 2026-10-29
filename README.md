# YT4S

A personal Mac app for downloading YouTube video or audio without a terminal.
SwiftUI, Apple Silicon, macOS 14+.
See `GLOSSARY.md` for vocabulary and `docs/adr/` for the architecture decisions.

## Install

YT4S needs an Apple Silicon Mac on macOS 14 or later.
It must live in `/Applications`, otherwise it cannot update itself.

### First install (DMG)

1. Download `YT4S-X.Y.Z.dmg` from the [latest release](https://github.com/njpobar/YT4S/releases/latest).
2. Open it and drag **YT4S** onto the **Applications** alias.
3. Open YT4S from Applications.
   macOS says it cannot check the app for malicious software, because YT4S is not notarized.
   Click **Done** (not Move to Trash).
4. Open **System Settings > Privacy & Security**, scroll to Security, and click **Open Anyway** next to "YT4S was blocked".
   Confirm with **Open Anyway** again and your password or Touch ID.

This is needed once.
Later versions arrive through the app's **Update app** button and open without the warning.

### Fallback: one-line install

If the DMG route fails, quit YT4S and paste this into Terminal.
It downloads the latest release's zip and replaces `/Applications/YT4S.app`.
Files fetched with `curl` are not quarantined, so there is no Open Anyway step.

```sh
curl -fsSL https://api.github.com/repos/njpobar/YT4S/releases/latest | grep -o 'https://[^"]*/YT4S-[0-9.]*\.zip' | head -1 | xargs curl -fL -o /tmp/YT4S.zip && rm -rf /Applications/YT4S.app && ditto -x -k /tmp/YT4S.zip /Applications && open /Applications/YT4S.app
```

## Layout

- `Sources/YT4S/`: the SwiftUI app shell (thin; links Sparkle 2).
- `Sources/YT4SCore/`: all testable logic, e.g. `Subprocess` and `YtDlpCommand`.
- `Tests/YT4SCoreTests/`: Swift Testing suites; `Fixtures/fake-yt-dlp` stands in for yt-dlp.
- `deps.lock`: pinned yt-dlp floor, Deno, ffmpeg and ffprobe (version, SHA-256, URL).
- `scripts/`: `fetch-deps.sh`, `update-deps.sh`, `build-app.sh`, `make-dmg.sh`, `release.sh`.
- `VERSION`: the app's semver, the single source of `CFBundleShortVersionString`.

## Test

```sh
swift test
```

Tests are offline: they drive `Tests/YT4SCoreTests/Fixtures/fake-yt-dlp`, whose behaviour is picked by `YT4S_FAKE_SCENARIO` (see the header of that script).

## Build the app

```sh
scripts/build-app.sh      # -> build/YT4S.app, ad-hoc signed, then gated
```

It fetches the binaries pinned in `deps.lock` into `vendor/` (cached, checksum-verified), builds a release binary, assembles and signs the bundle inside-out, then runs `codesign --verify --deep --strict` and each bundled tool from inside the app.

To bump a pinned binary, run `scripts/update-deps.sh <yt-dlp|deno|ffmpeg|ffprobe>`, review the printed line, and paste it into `deps.lock`.

## Release

```sh
scripts/release.sh --dry-run 1.2.3   # everything up to the checklist; no git or GitHub changes
scripts/release.sh 1.2.3
```

Run it on a clean `main` that matches `origin/main`, signed in to `gh`.
The version must be semver and newer than the last `vX.Y.Z` tag.
It runs `swift test`, the live contract test (still a stub until #32), then `scripts/build-app.sh` (build, sign, post-signing smoke gate), and writes `dist/YT4S-1.2.3.zip` and `dist/YT4S-1.2.3.dmg`.
It then prints the manual checklist (fresh DMG install + Open Anyway; app update from the previous release; yt-dlp update + rollback; playlist and channel runs with Cancel and Retry) and waits for you to type the version.
Only then does it commit the `VERSION` bump (if `VERSION` differs), tag `v1.2.3`, push `main` and the tag together, and create a **draft** GitHub Release with both files.
Nothing reaches users until you publish the draft on GitHub.

`CFBundleVersion` is the commit count of the tagged commit on `main`, so it only grows; `release.sh` refuses to run if the previous release tag is not an ancestor of `main`.

## Command Line Tools only (no Xcode)

Building SwiftUI + Sparkle, `scripts/build-app.sh`, and `swift test` with Swift Testing all work with just the Command Line Tools (verified with Swift 6.4, macOS 27.2).
Two quirks:

- SwiftPM's default build system does not hand the swift-testing macro plugin to the compiler under CLT, so `@Test` fails with "plugin for module 'TestingMacros' not found".
  `Package.swift` detects an active CLT developer dir and adds `-plugin-path` for the test target; under Xcode it does nothing.
- The linker warns that `/Library/Developer/CommandLineTools/Developer/usr/lib` and `.../Developer/Library/Frameworks` do not exist.
  SwiftPM adds those search paths itself; the warnings are harmless.
