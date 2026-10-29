# Research: Mac GUI stack options for a bundled yt-dlp wrapper

Ticket: [#2](https://github.com/njpobar/YT4S/issues/2). Map: [#1](https://github.com/njpobar/YT4S/issues/1). Date: 2026-10-25.

Constraints: arm64 only, macOS 14+, unsigned/ad-hoc signed, self-contained .app with yt-dlp + ffmpeg, two users, existing uv scaffold.

## TL;DR

- The bundled payload dominates size no matter the stack: about 250 MB uncompressed (yt-dlp_macos 37 MB, ffmpeg 66 MB, ffprobe 66 MB, deno 82 MB). GUI-stack overhead (a few MB for Swift/Tauri, roughly 100 MB for PySide6) is secondary.
- yt-dlp upstream recommends driving it as a CLI and parsing `--progress-template` / `--print` / `-J` output, not normal stdout. That makes "subprocess of the official standalone binary" the right integration on every stack, which also keeps the yt-dlp update model independent of the GUI stack.
- Once yt-dlp is a subprocess, Python's main advantage (in-process `yt_dlp` library) disappears.
- Recommendation: **native SwiftUI** (best native feel, lowest packaging pain, smallest overhead, Apple-maintained toolchain). Python fallback if Nick wants to stay in Python: **PySide6 + PyInstaller (onedir, `--windowed`, `--target-arch arm64`)**. Reject Flet and Tauri.
- Unverified empirically: no prototype was built. Sizes for stacks are estimates except where measured below.

## Stack-agnostic facts

### What must be bundled

- yt-dlp ships `yt-dlp_macos`, a "Universal MacOS (10.15+) standalone executable (recommended for MacOS)", and `yt-dlp_macos.zip`, an "Unpackaged MacOS (10.15+) executable (no auto-update)". Source: [yt-dlp README, release files](https://github.com/yt-dlp/yt-dlp#release-files). Latest release 2026.10.21: `yt-dlp_macos` is 37,180,736 bytes, the zip 53,879,210 bytes (GitHub Releases API, `gh api repos/yt-dlp/yt-dlp/releases/latest`).
- The standalone binaries "are built with the Python interpreter and the packages marked with \* included". Source: [README, Dependencies](https://github.com/yt-dlp/yt-dlp#dependencies).
- `ffmpeg`, `ffprobe`, `yt-dlp-ejs` and a JavaScript runtime are "highly recommended"; yt-dlp-ejs is "Required for full YouTube support", and "A JavaScript runtime/engine like deno (recommended), node.js, bun, or QuickJS is also required to run yt-dlp-ejs". Source: [README, Dependencies](https://github.com/yt-dlp/yt-dlp#dependencies).
- `--remote-components` "is currently not needed if you are using an official executable", meaning the official binary already carries yt-dlp-ejs. `--js-runtimes RUNTIME[:PATH]` points yt-dlp at a bundled runtime; "Only "deno" is enabled by default". Source: [README, General Options](https://github.com/yt-dlp/yt-dlp#general-options).
- So the .app must bundle a JS runtime too (deno recommended). deno 2.9.8 `deno-aarch64-apple-darwin.zip` is 38.8 MB, 81.5 MB unzipped (measured, [deno releases](https://github.com/denoland/deno/releases)).
- ffmpeg arm64: ffmpeg.org's only macOS link is evermeet.cx ([ffmpeg.org/download](https://ffmpeg.org/download.html)), which is Intel only: "I do not plan to provide native ffmpeg binaries for Apple Silicon ARM" ([evermeet.cx](https://evermeet.cx/ffmpeg/)). yt-dlp's own [FFmpeg-Builds](https://github.com/yt-dlp/FFmpeg-Builds/releases) publish Linux and Windows only. [martin-riedl.de](https://ffmpeg.martin-riedl.de/) offers static macOS arm64 ffmpeg/ffprobe (release 9.0.2), "signed (zip and installer)". Measured unzipped: ffmpeg 66.3 MB, ffprobe 66.2 MB.

### Driving yt-dlp and getting live progress

- "Your program should avoid parsing the normal stdout since they may change in future versions. Instead, they should use options such as `-J`, `--print`, `--progress-template`, `--exec` etc". Source: [README, Embedding yt-dlp](https://github.com/yt-dlp/yt-dlp#embedding-yt-dlp).
- `--newline` "Output progress bar as new lines"; `--progress-template [TYPES:]TEMPLATE` with `download:` / `postprocess:` prefixes, fields under `info` and `progress`; `--progress-delta SECONDS` throttles output. Source: [README, Verbosity and Simulation Options](https://github.com/yt-dlp/yt-dlp#verbosity-and-simulation-options).
- Implication: every stack reads line-delimited, app-defined progress lines from a child process. Progress handling is equivalent across stacks; only the subprocess API differs.
- Python in-process embedding with `progress_hooks` exists (same README section), but it ties yt-dlp's version to the frozen app, which conflicts with the "Update yt-dlp" button. Subprocess keeps the binary swappable.

### Signing and Gatekeeper (applies to every stack)

- On Apple silicon "the operating system enforces that any executable must be signed before it's allowed to run. There isn't a specific identity requirement for this signature: a simple ad-hoc signature is sufficient." Source: [macOS Big Sur 11.0.1 Universal Apps Release Notes, Code Signing](https://developer.apple.com/documentation/macos-release-notes/macos-big-sur-11_0_1-universal-apps-release-notes).
- macOS Sequoia: "users will no longer be able to Control-click to override Gatekeeper"; they must "visit System Settings > Privacy & Security". Source: [Apple Developer news](https://developer.apple.com/news/?id=saqachfa).
- Procedure: System Settings > Privacy & Security > Open Anyway, available "for about an hour after you try to open the app"; then it opens normally. Source: [Apple Support](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac).
- Without signing, a browser-downloaded app may show "that your application is broken and can not be started"; ad-hoc signing does not remove the Privacy & Security approval. Source: [Tauri macOS signing docs](https://v2.tauri.app/distribute/sign/macos/).
- Helper tools belong in `Contents/MacOS/` or `Contents/Helpers/`; misplaced code causes "hard-to-debug code signing and distribution problems". Source: [Apple, Placing content in a bundle](https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle).
- Note for the update-model ticket: Apple says the signing rule is designed to "better detect code modifications" (same release notes). Self-updating a binary inside the signed bundle is therefore risky; an updated yt-dlp should live outside the bundle (e.g. Application Support). Not verified further here.

## Per-stack comparison

| Stack | GUI overhead | Packaging pain | Subprocess progress | Native feel | Long-term maintenance | uv fit |
|---|---|---|---|---|---|---|
| SwiftUI (Xcode) | Few MB (system frameworks) | Low: Xcode builds, signs ad-hoc ("Sign to Run Locally"), nested helpers signed in build phase | `Foundation.Process` + `Pipe` | Best (AppKit/SwiftUI) | Apple-owned toolchain, stable | None (separate Swift project) |
| PySide6 + PyInstaller | ~100 MB est. (Essentials wheel is 116 MB universal2) | Medium: `--windowed` .app, `--target-arch arm64`, ad-hoc signs automatically, `--add-binary` for helpers | `QProcess` signals | Good (Qt widgets, Mac style), not pixel-native | Qt LGPL, large, mature | Good (`uv add pyside6-essentials pyinstaller`) |
| PySide6 + pyside6-deploy | Similar | Medium: Nuitka C compile, slower builds | `QProcess` | Good | Official Qt tool | Good (`[tool.pyside6.deploy]` in pyproject) |
| Toga + Briefcase | Smaller than Qt est. | Medium: `--adhoc-sign`, must set `universal_build = false`, own build env | asyncio subprocess | Native AppKit widgets | BeeWare, younger, smaller ecosystem | Partial (config in pyproject, Briefcase manages its own env) |
| py2app | n/a | Not researched deeply; superseded by the above for this use | - | - | - | - |
| Flet | Flutter engine | High: needs Xcode 15+, CocoaPods, Rosetta 2 | Python subprocess | Flutter look, not native | Extra Flutter/Dart layer | Partial |
| Tauri | <600 KB minimal + Rust | Medium: Rust + Node toolchains, `externalBin` sidecars with target triple | `CommandEvent::Stdout` | Web UI in system webview | Three languages | None |

### SwiftUI

- `Process`: "An object that represents a subprocess of the current process ... your program can run another program as a subprocess and monitor that program's execution." Source: [Apple, Process](https://developer.apple.com/documentation/foundation/process).
- Pros: zero runtime overhead beyond the payload, native List/ProgressView for the Queue, Xcode handles bundle layout and ad-hoc signing, no interpreter to freeze. One language end to end.
- Cons: Swift instead of Python; existing uv scaffold unused (would be replaced). Requires Xcode.

### PySide6 (PyInstaller or pyside6-deploy)

- `pyside6_essentials-6.12.0-cp310-abi3-macosx_14_0_universal2.whl` is 116.0 MB; LGPL-3.0 / GPL options. Source: [PyPI PySide6-Essentials](https://pypi.org/project/PySide6-Essentials/).
- PyInstaller: `--windowed` "On macOS this also triggers building a macOS .app bundle"; onefile + windowed "is not recommended ... require unpacking on each run"; `--target-arch` arm64/universal2; "If signing identity is not provided, ad-hoc signing is performed instead"; `--add-binary SOURCE:DEST`. Source: [PyInstaller usage](https://pyinstaller.org/en/stable/usage.html).
- pyside6-deploy is "a wrapper around Nuitka"; "macOS always produces an application bundle"; config in `pysidedeploy.spec` and `[tool.pyside6.deploy]` in pyproject.toml. Source: [Qt, pyside6-deploy](https://doc.qt.io/qtforpython-6/deployment/deployment-pyside6-deploy.html).
- Pros: stays in Python and uv, mature widgets (QTableView for the Queue), QProcess gives signal-based line reading.
- Cons: ~100 MB extra, Qt look is close but not native, freezing adds a build layer that can break on Python/Qt upgrades.

### Toga + Briefcase

- `toga-cocoa` uses AppKit via Rubicon Objective-C, "requires macOS 11 (Big Sur) or newer". Source: [Toga macOS](https://toga.beeware.org/en/stable/reference/platforms/macOS.html).
- ProgressBar, Table, DetailedList, MultilineTextInput, Selection all "Fully supported" on Cocoa. Source: [Toga API reference](https://toga.beeware.org/en/stable/reference/api/index.html).
- Briefcase: `--adhoc-sign` "produces an app that will be able to run on your own machine" (note: for two known Macs, it still runs after the Gatekeeper approval above); `universal_build` defaults to `true`; outputs DMG/zip/pkg. Source: [Briefcase macOS](https://briefcase.beeware.org/en/stable/reference/platforms/macOS/index.html).
- Pros: Python with real native widgets.
- Cons: smaller ecosystem, fewer escape hatches, Briefcase owns the build env rather than uv.

### Flet

- "Flutter, which we use for packaging, requires Rosetta 2 on Apple Silicon"; Xcode 15+ and CocoaPods 1.16+ required; ad-hoc signed by default; universal by default. Source: [Flet macOS publish](https://flet.dev/docs/publish/macos/).
- Rejected: heaviest toolchain, non-native look, extra Flutter layer for no gain.

### Tauri

- "a minimal Tauri app can be less than 600KB", uses the system webview, Rust backend. Source: [Tauri start](https://v2.tauri.app/start/).
- Sidecars via `bundle.externalBin`, each named with a target triple (`-aarch64-apple-darwin`), spawned with `app.shell().sidecar(...)`, stdout via `CommandEvent::Stdout`, needs `shell:allow-spawn` permission. Source: [Tauri sidecar](https://v2.tauri.app/develop/sidecar/).
- Ad-hoc signing via `signingIdentity: "-"`. Source: [Tauri macOS signing](https://v2.tauri.app/distribute/sign/macos/).
- Rejected: Rust + JS + web UI is three layers for a small native utility, and the size win is irrelevant next to the 250 MB payload.

## Recommendation

1. **SwiftUI** as the primary choice. The app is a thin native shell around three subprocess binaries; Swift gives the best native feel for Sarah, the simplest packaging/signing path, and no freezing layer to maintain. Python buys nothing once yt-dlp is a subprocess.
2. **PySide6 + PyInstaller** if staying in Python is a hard preference. Use onedir + `--windowed` + `--target-arch arm64`, ship helpers in `Contents/MacOS` or `Contents/Helpers`.
3. Regardless of stack: subprocess the official `yt-dlp_macos` (or the unpacked zip, which avoids per-run unpack), bundle arm64 ffmpeg/ffprobe (martin-riedl.de) and deno, pass `--ffmpeg-location` and `--js-runtimes deno:<path>`, parse a custom `--progress-template` with `--newline`.
4. Document first-launch: Privacy & Security > Open Anyway (one time per app release, per Mac).

## Open questions / not verified

- No prototype built; native-feel and real bundle sizes per stack are estimates.
- Whether deno can be swapped for a smaller runtime (QuickJS) without YouTube breakage.
- Whether replacing an ad-hoc-signed app on update re-triggers the Gatekeeper approval each release (relevant to the "Update app" button).
- ffmpeg licensing of the martin-riedl builds (page does not state GPL vs LGPL config).
