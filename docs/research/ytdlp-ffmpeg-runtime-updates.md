# Research: yt-dlp and ffmpeg runtime update and rollback mechanics

Ticket: [#3](https://github.com/njpobar/YT4S/issues/3).
Researched 2026-10-25 against yt-dlp `master` @ `fa98866` and release `2026.10.21`.

## TL;DR recommendation

- Ship yt-dlp as the upstream **`yt-dlp_macos.zip` (PyInstaller onedir)** build, run as a subprocess. Not the Python package, not the onefile `yt-dlp_macos`.
- Bundled copy lives read-only inside the `.app` (the known-good floor). Updates go to versioned dirs under `~/Library/Application Support/<bundle-id>/yt-dlp/<tag>/`, plus a small `active` pointer file. Rollback = flip the pointer to the previous dir.
- Do NOT use `yt-dlp -U`. Implement the update in the app: GitHub release API -> download zip + `SHA2-256SUMS` -> verify SHA-256 -> unzip to temp dir -> atomic rename into place -> smoke test (`--version`) -> flip pointer.
- Also bundle a JS runtime (**Deno**, arm64) - required for full YouTube support now.
- ffmpeg + ffprobe: arm64 static builds from **ffmpeg.martin-riedl.de** (release channel, signed by Developer ID, SHA-256 per file). GPLv3 build; fine for 2-user personal use, ship license + source link.
- "Skip if still in target folder": no yt-dlp flag for this independent of the archive, but yt-dlp natively skips when the exact final filename already exists. Recommended: app-owned ledger of `(extractor id, final filepath)` -> at queue start, write a temp `--download-archive` containing only entries whose file still exists.

## 1. Which yt-dlp artifact

Upstream release files for macOS ([README "Release files"](https://github.com/yt-dlp/yt-dlp#release-files)):

| File | What | Notes |
| --- | --- | --- |
| `yt-dlp_macos` | Universal (x86_64 + arm64) standalone, macOS 10.15+ | "recommended for MacOS"; self-updates |
| `yt-dlp_macos.zip` | Unpackaged executable (onedir) | "no auto-update" via `-U` |
| `yt-dlp` | zipimport, needs system Python | not usable for Sarah |

Measured locally (M-series, macOS 27, release 2026.10.21):

- `yt-dlp_macos` (onefile): ~4.4-5.6 s per invocation for `--version`, every time (PyInstaller unpacks to a temp dir on each launch). 37 MB.
- `yt-dlp_macos.zip` (onedir): ~5 s first launch (system scan), then **~0.2 s**. 54 MB zip, 123 MB unpacked.
- Both are ad-hoc signed (`Signature=adhoc`), universal Mach-O. Ad-hoc signing is sufficient for arm64 execution.
- `-v` reports variant `darwin_dir`, Python 3.14, bundled `curl_cffi`, `mutagen`, `websockets`, `yt_dlp_ejs` (verified via `yt-dlp_macos -v`).

Why the standalone over embedding the Python package:

- Process isolation: cancel = kill the process; a yt-dlp crash cannot take down the GUI.
- Stack-agnostic: works whatever GUI stack is chosen.
- Upstream builds bundle the right native deps (curl_cffi for impersonation, ejs). Reproducing that with pip wheels in an updatable site dir is more fragile.
- The "no auto-update" note on the zip is irrelevant - we own the update path.

Integration notes from the README:

- Do not parse normal stdout; use `-J`, `--print`, `--progress-template`, `--exec` ([README "Embedding"](https://github.com/yt-dlp/yt-dlp#embedding-yt-dlp)).
- Pass `--ignore-config` so a user-level yt-dlp config on Nick's machine cannot change app behavior.
- Pass `--no-update` to silence the "older than 90 days" warning ([README "Update"](https://github.com/yt-dlp/yt-dlp#update)).
- Point at bundled tools explicitly: `--ffmpeg-location <path>` and `--js-runtimes deno:<path>`.
  Locally `-v` picked up `ffmpeg` and `deno` from Nick's PATH; Sarah has neither, so explicit paths are required.

## 2. Release channels

From [README "Update channels"](https://github.com/yt-dlp/yt-dlp#update-channels):

- `stable` (`yt-dlp/yt-dlp`): ~monthly; "often stale and prone to external breakage".
- `nightly` (`yt-dlp/yt-dlp-nightly-builds`): daily when there are changes; "the **recommended channel for regular users**".
- `master` (`yt-dlp/yt-dlp-master-builds`): every push; may regress.

Current: stable `2026.10.21`, nightly `2026.10.23.233055`.
Recommendation: "Update yt-dlp" pulls latest **nightly** (upstream's own advice); the bundled floor is whatever tag the app release was built with.
This is a product call; stable also works with the same mechanism (only the repo name changes).

## 3. Why not `yt-dlp -U`

Source: [`yt_dlp/update.py`](https://github.com/yt-dlp/yt-dlp/blob/master/yt_dlp/update.py).

- Writes `<exe>.new`, renames current to `<exe>.old`, renames new into place, then **deletes `.old`** (lines ~511-560). No retained previous version, so no rollback.
- Requires write access to the exe's directory - that is inside the `.app`, which we must not modify.
- `darwin_dir` (the zip build) is explicitly non-updateable (`_NON_UPDATEABLE_REASONS`).

What it does that we should copy:

- Downloads `SHA2-256SUMS` from the same release, finds the line ending with the binary name, compares SHA-256; refuses on mismatch.
- Honors `_update_spec` (a per-release lock file, lines `lockV2 <repo> <tag> <regex>` matched against `"<variant> <system identifier>"`) so old OSes/Pythons stop at a max tag.
  Current file has no lock for `darwin_exe`/`darwin_dir`, so not needed for macOS 14+ today. Cheap to honor anyway: if a lock line matches `darwin_dir`, cap at that tag.

## 4. Where updated copies live

- App bundle stays immutable. Apple: modifying signed code in place causes `Code Signature Invalid` crashes because the kernel caches signature info; write to a temp file and replace instead ([Apple, Updating Mac Software](https://developer.apple.com/documentation/security/updating-mac-software)).
  Modifying the bundle also breaks its seal.
- Mutable app data goes in `~/Library/Application Support/<bundle-id>/` ([`applicationSupportDirectory`](https://developer.apple.com/documentation/foundation/filemanager/searchpathdirectory/applicationsupportdirectory); convention of a bundle-id subdir per Apple's File System Programming Guide).
- Quarantine: files an app creates are quarantined only if it sets `LSFileQuarantineEnabled` ("whether the files this app creates are quarantined by default", [Apple](https://developer.apple.com/documentation/bundleresources/information-property-list/lsfilequarantineenabled)). Leave it unset; downloaded yt-dlp then runs without Gatekeeper prompts. Observed downloaded binary only carried `com.apple.provenance`, and ran fine.

Proposed layout:

```
YT4S.app/Contents/Resources/bin/yt-dlp/<bundled-tag>/   # floor, read-only
~/Library/Application Support/<bundle-id>/yt-dlp/
  2026.10.23.233055/        # unpacked onedir
  2026.10.21.xxxxxx/        # previous
  state.json                # {"active": "...", "previous": "...", "last_good": "..."}
```

Resolution at launch: `active` if its dir exists and passes `--version`, else `previous`, else the bundled floor.
Keep 2 downloaded versions (active + previous); prune older. If the bundled floor is newer than `active` (after an app update), prefer the floor.

## 5. Update algorithm

1. `GET https://api.github.com/repos/yt-dlp/yt-dlp-nightly-builds/releases/latest` (unauthenticated is fine at our volume). Read `tag_name`.
   Release assets also expose a `digest` field (`sha256:...`) in the API response - a second source for the hash.
2. If tag == active: "already up to date".
3. Download `yt-dlp_macos.zip` and `SHA2-256SUMS` from `https://github.com/<repo>/releases/download/<tag>/<name>`.
4. Verify SHA-256 of the zip against the `SHA2-256SUMS` line for `yt-dlp_macos.zip`. Abort on mismatch or missing line (stricter than upstream, which only warns).
   Optional stronger check: `SHA2-256SUMS.sig` GPG signature against the pinned [`public.key`](https://github.com/yt-dlp/yt-dlp/blob/master/public.key) (README "Release files"). Needs a bundled OpenPGP verifier since macOS has no `gpg`; TLS + checksum matches what upstream's own updater trusts.
5. Unzip into `yt-dlp/.staging-<tag>/`, `chmod +x`, run `yt-dlp_macos --version`, expect it to print `<tag>`.
6. `rename` staging dir to `yt-dlp/<tag>/` (atomic, same volume). Write `state.json` via temp file + rename. Never touch files of a version that may be running.
7. Rollback button: swap `active` and `previous`. No network needed.

Run updates only when the Queue is idle (a running onedir copy is not modified anyway, but it keeps semantics simple).

## 6. JS runtime (new hard dependency)

- yt-dlp needs an external JS runtime to solve YouTube JS challenges; `yt-dlp-ejs` is bundled in the PyInstaller builds incl. `yt-dlp_macos` ([wiki: EJS](https://github.com/yt-dlp/yt-dlp/wiki/EJS)).
- Deno >= 2.3.0 is recommended and the only runtime enabled by default; others need `--js-runtimes`. Path override: `--js-runtimes "deno:/path/to/deno"`.
- Source: [denoland/deno releases](https://github.com/denoland/deno/releases) `deno-aarch64-apple-darwin.zip` with `.sha256sum` (latest v2.9.8). MIT.
- Bundle a pinned Deno in the `.app`; update it with app releases, not via the yt-dlp button.

## 7. ffmpeg / ffprobe

Both required: merging separate video/audio and post-processing ([README "Dependencies"](https://github.com/yt-dlp/yt-dlp#dependencies)).

Sources checked:

- [yt-dlp/FFmpeg-Builds](https://github.com/yt-dlp/FFmpeg-Builds/releases): Linux + Windows only. No macOS.
- [ffmpeg.org/download](https://ffmpeg.org/download.html): only macOS static link is evermeet.cx.
- [evermeet.cx](https://evermeet.cx/ffmpeg/): Intel only; author: "I do not plan to provide native ffmpeg binaries for Apple Silicon ARM." Out.
- [ffmpeg.martin-riedl.de](https://ffmpeg.martin-riedl.de/): macOS arm64 static `ffmpeg`, `ffprobe` (release 9.0.2 and snapshot), "macOS binaries are signed (zip and installer)", per-file `.sha256`, open build script. Redirect URL: `https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffmpeg.zip`.

Verified the downloaded release build: arm64, links only system frameworks/libs (`otool -L`), Developer ID signed (TeamIdentifier `KU3N25YGLU`), configure includes `--enable-gpl --enable-version3` plus libx264/libx265/libmp3lame/libopus.

Recommendation: pin a release build in the `.app` (download + verify SHA-256 in the app build script); update only with app releases. ffmpeg changes rarely break yt-dlp, unlike extractors.
Fallback if that source disappears: build from source in CI (only need a small config: native AAC/Opus, libmp3lame, mp4/webm/mkv muxers).

Licensing ([ffmpeg.org/legal](https://ffmpeg.org/legal.html)): default LGPL 2.1+; "If those parts get used the GPL applies to all of FFmpeg" (`--enable-gpl`). This build is GPLv3.
For a private 2-person app this is low risk. If the .app is ever shared, GPL conveyance applies: include ffmpeg's license text, the configure line, and a link to matching source / the build script. Do this anyway in an "Acknowledgements" file; it costs nothing.
yt-dlp itself is Unlicense; bundled components' licenses are in `_internal/THIRD_PARTY_LICENSES.txt` of the zip build.

## 8. Detecting "already present in target folder"

yt-dlp has no option for "skip if the file exists anywhere / regardless of name". What exists:

- **Native final-filename check** (default on). In `YoutubeDL.process_info`, `existing_video_file()` builds the expected output path (also with `final_ext`, e.g. `.mp3` from `--audio-format`) and if it exists and `overwrites` is not set, reports "has already been downloaded" and skips ([`YoutubeDL.py` `existing_file`/`existing_video_file`](https://github.com/yt-dlp/yt-dlp/blob/master/yt_dlp/YoutubeDL.py)). `--force-overwrites` disables it; `-w/--no-overwrites` extends it to metadata files.
  Limits: happens only *after* full extraction of each video (slow for big channels; one page fetch per video), and only matches if the rendered Naming pattern is identical (title edits upstream or a pattern change -> re-download).
- **`--download-archive FILE`**: lines `<extractor_key lowercased> <id>`. Checked *before* extraction using the URL's temp id (`_match_entry` / `get_temp_id`), so channel/playlist entries skip cheaply. But it ignores whether the file still exists.

Recommended combo (satisfies "removed files re-download"):

1. After each successful item, capture `--print "after_move:%(extractor_key)s %(id)s %(filepath)s"` (or `--print-to-file`) into an app-owned ledger (Application Support).
2. At Queue start, build a **temp archive file** containing `<extractor> <id>` only for ledger rows whose `filepath` still exists on disk. Pass it with `--download-archive`.
3. Native filename check stays on as a second line of defense (covers files that predate the ledger, if the pattern matches).

Optional: include `[%(id)s]` in preset Naming patterns so the ledger can be rebuilt by scanning the folder if it is lost; not required.

## Open questions for the PRD / ADR

- Channel for the update button: nightly (upstream recommendation) vs stable.
- Whether to add GPG verification of `SHA2-256SUMS.sig` or accept TLS + SHA-256.
- Whether Deno and ffmpeg also get an in-app update path (recommend no; app releases only).
