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
- `scripts/`: `fetch-deps.sh`, `update-deps.sh`, `build-app.sh`, `write-info-plist.sh`, `make-dmg.sh`, `write-appcast.sh`, `release.sh`.
- `config/sparkle-public-key`: the EdDSA public key app updates are verified against.
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

`scripts/write-info-plist.sh` writes the Info.plist: the Sparkle feed (`releases/latest/download/appcast.xml`) and the EdDSA public key from `config/sparkle-public-key`.
While that file is empty, builds work but cannot update themselves.

The app refuses to run outside `/Applications` (it shows a "Move YT4S to Applications" screen).
To run a development build from `build/`, pass the override:

```sh
open build/YT4S.app --args -YT4SAllowAnyLocation YES
```

## Release

```sh
scripts/release.sh --dry-run 1.2.3   # everything up to the checklist; no git or GitHub changes
scripts/release.sh 1.2.3
```

Run it on a clean `main` that matches `origin/main`, signed in to `gh`.
The version must be semver and newer than the last `vX.Y.Z` tag.
It first checks that the Sparkle signing key in your login Keychain matches `config/sparkle-public-key`, so a release can never ship an update installed apps would reject.
It runs `swift test`, the live contract test (still a stub until #32), then `scripts/build-app.sh` (build, sign, post-signing smoke gate), and writes `dist/YT4S-1.2.3.zip`, `dist/appcast.xml` and `dist/YT4S-1.2.3.dmg`.
`scripts/write-appcast.sh` EdDSA-signs the zip with Sparkle's `sign_update` (key from the Keychain) and writes a single-entry appcast (no deltas) pointing at the zip on the `v1.2.3` release.
It then prints the manual checklist (fresh DMG install + Open Anyway; app update from the previous release; yt-dlp update + rollback; playlist and channel runs with Cancel and Retry) and waits for you to type the version.
Only then does it commit the `VERSION` bump (if `VERSION` differs), tag `v1.2.3`, push `main` and the tag together, and create a **draft** GitHub Release with the zip, `appcast.xml` and the DMG.
Nothing reaches users until you publish the draft on GitHub: installed apps read `releases/latest/download/appcast.xml`, which only resolves to published releases.

`CFBundleVersion` is the commit count of the tagged commit on `main`, so it only grows; `release.sh` refuses to run if the previous release tag is not an ancestor of `main`.

### Signing key for app updates (one time)

Sparkle verifies every app update against an EdDSA public key baked into the app.
The private key lives only in Nick's login Keychain; `release.sh` refuses to run without it.

1. Resolve the package once so Sparkle's tools exist: `swift package resolve`.
2. Create the key in your login Keychain and print its public half (allow the Keychain prompt):
   `.build/artifacts/sparkle/Sparkle/bin/generate_keys`
3. Paste the printed public key (the `SUPublicEDKey` value, base64) on its own line at the end of `config/sparkle-public-key`, and commit it.
   Every build from then on can update itself.
4. Back up the private key somewhere safe (e.g. a password manager):
   `.build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private-key.txt`, store it, then delete the file.
   If it is lost, installed copies can never update again; Sarah would have to reinstall from a DMG.

On a new Mac, import the backup with `generate_keys -f sparkle-private-key.txt`.
`generate_keys -p` prints the public key the Keychain holds; it must equal `config/sparkle-public-key`.

### Test an app update locally

To try an update end to end without GitHub, build two versions that trust a throwaway key and read a localhost feed:

1. Make a throwaway key with `openssl genpkey -algorithm ed25519 -outform DER -out k.der`; the last 32 bytes, base64-encoded, are the private key file for `sign_update --ed-key-file`, and `openssl pkey -inform DER -in k.der -pubout -outform DER | tail -c 32 | base64` is the public key.
2. Build each version with `YT4S_VERSION`, `YT4S_BUILD_NUMBER`, `YT4S_SPARKLE_PUBLIC_KEY=<public key>` and `YT4S_FEED_URL=http://127.0.0.1:8765/appcast.xml` set for `scripts/build-app.sh`.
3. Zip the newer one with `ditto -c -k --sequesterRsrc --keepParent`, then run `scripts/write-appcast.sh` with `YT4S_SPARKLE_BIN` pointing at a directory whose `sign_update` wraps the real one with `--ed-key-file`.
4. Serve that directory with `python3 -m http.server 8765 --bind 127.0.0.1`, put the older app in `/Applications`, open it, and click **Update app** once its dot shows.

## Command Line Tools only (no Xcode)

Building SwiftUI + Sparkle, `scripts/build-app.sh`, and `swift test` with Swift Testing all work with just the Command Line Tools (verified with Swift 6.4, macOS 27.2).
Two quirks:

- SwiftPM's default build system does not hand the swift-testing macro plugin to the compiler under CLT, so `@Test` fails with "plugin for module 'TestingMacros' not found".
  `Package.swift` detects an active CLT developer dir and adds `-plugin-path` for the test target; under Xcode it does nothing.
- The linker warns that `/Library/Developer/CommandLineTools/Developer/usr/lib` and `.../Developer/Library/Frameworks` do not exist.
  SwiftPM adds those search paths itself; the warnings are harmless.
