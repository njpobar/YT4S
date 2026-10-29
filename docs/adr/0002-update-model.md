# Update model: user-clicked app and yt-dlp updates with rollback

YT4S has two independent update buttons in the footer.
Nothing is downloaded or installed without a click.
The app checks for both on launch and, if left open, once a day; a found update only shows a badge on its button.

## App

- Sparkle 2 with EdDSA signatures, ad-hoc signed, Hardened Runtime off.
- The appcast is a release asset on this repo's GitHub Releases.
- Updates never go through the browser, and `LSFileQuarantineEnabled` is never set, so in-app updates carry no quarantine attribute and skip Gatekeeper.
- A spike confirmed an ad-hoc signed bundle swaps itself and relaunches without a prompt on macOS 27.2.
  Sarah's Mac is an M1 on whatever the latest macOS is; we assume it behaves the same.
- First install is a DMG with an Applications alias.
  Nick walks Sarah through Open Anyway once.
  The app refuses to run outside `/Applications` and asks the user to move it, because translocation breaks self-update.
  A one-line `curl` install is the documented fallback.

## yt-dlp

- The upstream `yt-dlp_macos.zip` (onedir) runs as a subprocess; `yt-dlp -U` is never used.
- The channel is nightly.
- The bundled copy inside the `.app` is the read-only floor, shipped with each app release.
- Update flow: fetch the latest release, download the zip and `SHA2-256SUMS`, verify, unzip to staging, run a `--version` smoke test, rename atomically to `~/Library/Application Support/<bundle-id>/yt-dlp/<tag>/`, flip the `state.json` pointer.
- Keep the active copy plus exactly one previous.
  Rollback swaps the pointer, works offline, and pins the older version until the user clicks Update again, so the launch check does not re-offer the bad one.
  The fallback chain is active, previous, bundled.
  When no downloaded previous copy exists (after the first update, or once the previous one was pruned as older than bundled), Roll back returns to the bundled copy, so a bad first nightly can be undone offline.
  In `state.json` an empty `active` means the bundled copy is in use; after Roll back is used, Roll back stays disabled until the next Update click (only one step back).
  At launch each copy is tried with `--version`; if none starts, the window shows only "YT4S is damaged. Reinstall the app." with Update app.
- At launch the app uses whichever is newer, the downloaded active copy or the bundled one, and prunes downloaded copies older than the bundled one.
- Deno and ffmpeg/ffprobe are pinned per app release and are not touched by the button.
- yt-dlp is always invoked with `--ignore-config --no-update --ffmpeg-location ... --js-runtimes deno:...`.

## Shared behaviour

- Both buttons are disabled while any download is running, with a hint to finish or cancel the Queue first.
- On any failure (offline, checksum mismatch, smoke-test failure, bad signature) the current version stays, staging is discarded, and the footer shows a plain two to three line explanation of what failed and what to do.
  There are no retries and no partial installs.
- A failed video whose error looks like an outdated yt-dlp makes the failure banner point at Update yt-dlp.
  The banner never runs the update itself.

## Considered Options

- **`yt-dlp -U`**: replaces in place and deletes the old copy, so no rollback, and it would write inside the signed `.app`.
- **Stable channel**: fewer regressions, but slower fixes when YouTube breaks, and rollback already covers nightly regressions.
- **Silent auto-updates**: rejected; the user wants every install to be a click.
- **Gating yt-dlp updates on Nick-blessed pins**: out of scope for v1.

## Consequences

The app owns a small updater for yt-dlp (download, verify, stage, smoke test, pointer flip).
Each app release must re-pin Deno, ffmpeg and the bundled yt-dlp floor, which feeds the release-process work.
