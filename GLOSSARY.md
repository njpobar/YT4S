# YT4S

A personal Mac app for downloading YouTube video or audio without a terminal, used only by its two owners.

## Language

**Source**:
What the user pastes in to say what to download: a single video link, a list of links, a channel, or a playlist.
A video link that also names a playlist (`watch?v=...&list=...`, as copied while playing a playlist or Mix) is a single video; the playlist's own page link is the Playlist source.
_Avoid_: Input, URL, target

**Channel source**:
A Source naming a YouTube channel; it means every video on that channel's Videos tab (or its Shorts or Live tab when the link names one).
_Avoid_: Subscription

**Playlist source**:
A Source naming a YouTube playlist; it means every video in that playlist.

**Format**:
Whether a download is kept as video or as MP3 audio.
_Avoid_: Mode, type

**Quality preset**:
One of a few fixed video quality choices (e.g. Best, 1080p, 720p) offered instead of raw codec settings.

**Naming pattern**:
The rule that turns a video's details into its saved file name and folder; chosen from presets, or written custom in advanced mode.
_Avoid_: Naming convention, template

**Custom Naming pattern**:
A Naming pattern Nick writes himself, behind the advanced toggle, in yt-dlp's output template language (e.g. `%(channel)s/%(title)s`).
It sets the whole path below the Download folder, replacing the presets' folders and index prefix; YT4S still adds the extension and applies the same name cleanup.
"Template" names only that language, never the pattern itself.
_Avoid_: Custom template, output template (for the pattern)

**Queue**:
The visible list of pending, running, finished, and failed downloads.

**Already downloaded**:
A video whose Format is already present in the Download folder, so it is skipped rather than fetched again.
_Avoid_: Duplicate

**Download folder**:
The single folder the user picks in the app where all downloads are saved.
_Avoid_: Target folder, destination
