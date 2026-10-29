# YT4S

A personal Mac app for downloading YouTube video or audio without a terminal.
SwiftUI, Apple Silicon, macOS 14+.
See `GLOSSARY.md` for vocabulary and `docs/adr/` for the architecture decisions.

## Layout

- `Sources/YT4S/`: the SwiftUI app shell (thin; links Sparkle 2).
- `Sources/YT4SCore/`: all testable logic, e.g. `Subprocess` and `YtDlpCommand`.
- `Tests/YT4SCoreTests/`: Swift Testing suites; `Fixtures/fake-yt-dlp` stands in for yt-dlp.
- `deps.lock`: pinned yt-dlp floor, Deno, ffmpeg and ffprobe (version, SHA-256, URL).
- `scripts/`: `fetch-deps.sh`, `update-deps.sh`, `build-app.sh`.

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

## Command Line Tools only (no Xcode)

Building SwiftUI + Sparkle, `scripts/build-app.sh`, and `swift test` with Swift Testing all work with just the Command Line Tools (verified with Swift 6.4, macOS 27.2).
Two quirks:

- SwiftPM's default build system does not hand the swift-testing macro plugin to the compiler under CLT, so `@Test` fails with "plugin for module 'TestingMacros' not found".
  `Package.swift` detects an active CLT developer dir and adds `-plugin-path` for the test target; under Xcode it does nothing.
- The linker warns that `/Library/Developer/CommandLineTools/Developer/usr/lib` and `.../Developer/Library/Frameworks` do not exist.
  SwiftPM adds those search paths itself; the warnings are harmless.
