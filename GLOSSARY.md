# YT4S

A personal Mac app for downloading YouTube video or audio without a terminal, used only by its two owners.

## Language

**Source**:
What the user pastes in to say what to download: a single video link, a list of links, a channel, or a playlist.
_Avoid_: Input, URL, target

**Channel source**:
A Source naming a YouTube channel; it means every video on that channel.
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

**Queue**:
The visible list of pending, running, finished, and failed downloads.

**Already downloaded**:
A video whose Format is already present in the Download folder, so it is skipped rather than fetched again.
_Avoid_: Duplicate

**Download folder**:
The single folder the user picks in the app where all downloads are saved.
_Avoid_: Target folder, destination
