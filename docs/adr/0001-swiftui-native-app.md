# Build YT4S as a native SwiftUI app

YT4S is a SwiftUI app for Apple Silicon on macOS 14+, written by Claude, that drives the bundled upstream `yt-dlp_macos` as a subprocess.
yt-dlp's own guidance is to run it as a CLI rather than embed it, which removes Python's main advantage, and SwiftUI gives the smallest native bundle plus Sparkle 2 for app self-update under ad-hoc signing.

## Considered Options

- **HTML UI + Python in a pywebview window**: lowest-stress to build and easy to restyle, but ~100 MB extra and a hand-rolled app updater instead of Sparkle.
- **HTML page + local server in the browser**: a tab is not an app for Sarah, and the server outlives the tab.
- **PySide6, Toga, Flet, Tauri**: see [GUI stack research](https://github.com/njpobar/YT4S/blob/research/gui-stack/docs/research/gui-stack.md).

## Consequences

The existing `uv` Python scaffold (`pyproject.toml`, `src/yt4s/`) is superseded and gets replaced by an Xcode/SwiftPM project.
