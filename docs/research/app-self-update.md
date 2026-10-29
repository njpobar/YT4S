# Research: unsigned Mac app self-update from GitHub Releases

Ticket: [#4](https://github.com/njpobar/YT4S/issues/4). Researched 2026-10-25.

## Question

Can an ad-hoc signed, unnotarized YT4S (Apple Silicon, macOS 14+) update itself from this repo's GitHub Releases without Sarah fighting Gatekeeper each time?
What first-install friction remains?

## Answer

Yes.
Gatekeeper's first-launch prompt is driven by the `com.apple.quarantine` attribute, and an app that downloads its own update with a normal networking API (not a browser) does not set that attribute.
So only the first install hits Gatekeeper; in-app updates replace the bundle silently.
The first install on macOS 15+ needs a one-time trip to System Settings > Privacy & Security > Open Anyway (Control-click Open no longer works).

## Findings

### 1. Ad-hoc signing is mandatory and sufficient to run, but cannot pass Gatekeeper

- On Apple Silicon "the operating system enforces that any executable must be signed before it's allowed to run", and "a simple ad-hoc signature is sufficient." [Big Sur 11.0.1 Universal Apps release notes](https://developer.apple.com/documentation/macos-release-notes/macos-big-sur-11_0_1-universal-apps-release-notes)
- Same source: "binaries signed this way cannot pass through Gatekeeper."
- Implication: every Mach-O in the bundle (bundled yt-dlp, ffmpeg, Python runtime) must carry a valid ad-hoc signature (`codesign -s -`), and must be re-signed if modified after linking.

### 2. Gatekeeper is triggered by quarantine, which only user-level download apps set

- "User-level apps on macOS implement a quarantine system for new downloads. For example, if Safari downloads a zip archive, it quarantines that archive." [Quinn (Apple DTS), Resolving Trusted Execution Problems, rev. 2025-08-06](https://developer.apple.com/forums/thread/706442)
- "running a quarantined app always invokes Gatekeeper." Same source, which also warns the system "may run Gatekeeper at other times as well" and that this "is not documented and changes over time."
- "Unix-y networking tools, like `curl` and `scp`, don't quarantine the files they download. Unix-y unarchiving tools, like `tar` and `unzip`, don't propagate quarantine." Same source.
- `LSFileQuarantineEnabled` is the Info.plist key controlling "whether the files this app creates are quarantined by default." [Apple docs](https://developer.apple.com/documentation/bundleresources/information-property-list/lsfilequarantineenabled) A non-sandboxed app that does not set it does not quarantine its own downloads.
- Quarantine can be checked/cleared programmatically via `URLResourceKey.quarantinePropertiesKey` (the xattr itself is not API). Same Quinn source.
- Caveat: Apple's Platform Security guide says "Gatekeeper also tracks the provenance of files written by downloaded software" and "all software in macOS is checked for known malicious content the first time it's opened, regardless of how it arrived." [Gatekeeper and runtime protection](https://support.apple.com/guide/security/gatekeeper-and-runtime-protection-sec5599b66df/web) The malware (XProtect) scan applies to everything, but the user-approval prompt is tied to quarantine. Provenance effects on a self-replaced ad-hoc bundle are undocumented: verify empirically (see Open risks).

### 3. macOS 15+ removed the Control-click bypass

- "In macOS Sequoia, users will no longer be able to Control-click to override Gatekeeper when opening software that isn't signed correctly or notarized. They'll need to visit System Settings > Privacy & Security." [Apple Developer News, 2024-08-06](https://developer.apple.com/news/?id=saqachfa)
- Current steps: System Settings > Privacy & Security > Security > Open Anyway, then enter login password; the button "is available for about an hour after you try to open the app." [Mac User Guide](https://support.apple.com/guide/mac-help/open-an-app-by-overriding-security-settings-mh40617/mac)
- After that, "The app is now saved as an exception to your security settings, and you can open it in the future by double-clicking it." [Safely open apps on your Mac](https://support.apple.com/en-us/102445)
- On macOS 14 the Control-click > Open path still works; the Settings path works on both.

### 4. App translocation must be avoided before self-update can work

- "When necessary, Gatekeeper opens apps from randomized, read-only locations." [Platform Security guide](https://support.apple.com/guide/security/gatekeeper-and-runtime-protection-sec5599b66df/web)
- Sparkle refuses to update a translocated app and tells the user to "move it into your Applications folder, relaunch it from there", detecting it by `/AppTranslocation/` in the bundle path. [Sparkle SPUUpdateDriver.m / SUHost.m](https://github.com/sparkle-project/Sparkle/blob/2.x/Sparkle/SUHost.m)
- Implication: the first-install flow must get the app into `/Applications` (drag from DMG/Finder move) before first launch, and the updater should detect `/AppTranslocation/` and show the same instruction.

### 5. Sparkle works without a Developer ID

- Sparkle's update policy allows an ad-hoc signed app: "If no Apple Code Signing certificate is available, adhoc signing can be used at minimum." A bundle update is accepted if "old and new Ed(DSA) public keys are the same and valid ... or old and new Code Signing identity are the same and valid." [SUUpdateValidator.m](https://github.com/sparkle-project/Sparkle/blob/2.x/Sparkle/SUUpdateValidator.m)
- So with no Developer ID, EdDSA (ed25519) signing of each release archive is the only trust anchor: `generate_keys` puts the private key in the login Keychain and the public key goes in `Info.plist` as `SUPublicEDKey`. [Sparkle docs](https://sparkle-project.org/documentation/)
- Sparkle's installer strips quarantine from the new bundle ("Release our new app from quarantine") and, on macOS 14.4+, pre-warms with `gktool scan`. [SUPlainInstaller.m](https://github.com/sparkle-project/Sparkle/blob/2.x/Autoupdate/SUPlainInstaller.m)
- Gotcha: with Hardened Runtime's Library Validation on, the system "may not let your application load Sparkle if you attempt to sign ... via an ad-hoc signature." [Sparkle docs](https://sparkle-project.org/documentation/) Hardened Runtime is only needed for notarization, so leave it off.
- App Management (macOS 13+) blocks modifications across different Team IDs; Sparkle's own message notes this only surfaces "for external app updaters ... that update other app bundles", not an app updating itself. [SPUInstallerDriver.m](https://github.com/sparkle-project/Sparkle/blob/2.x/Sparkle/SPUInstallerDriver.m), [WWDC22 What's new in privacy](https://developer.apple.com/videos/play/wwdc2022/10096/)
- Sparkle is an Objective-C/Swift framework. Natural for a Swift/SwiftUI stack; awkward from Python (PyObjC bridging or shelling out to `sparkle-cli`).

### 6. GitHub Releases as the feed

- `GET /repos/{owner}/{repo}/releases/latest` returns "the most recent non-prerelease, non-draft release." [GitHub REST docs](https://docs.github.com/en/rest/releases/releases#get-the-latest-release)
- Stable asset URL: `/releases/latest/download/<asset-name>`. [GitHub docs](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases) Works as a Sparkle `SUFeedURL` for an `appcast.xml` uploaded as a release asset.

## Options

| Option | Fit |
| --- | --- |
| Sparkle 2 + EdDSA + appcast as release asset | Best if stack is Swift/SwiftUI. Battle-tested swap/relaunch, translocation handling, signature check. |
| Hand-rolled updater (any stack) | Query GitHub API, download zip with URLSession/urllib (no quarantine), verify ed25519 or SHA-256 from release, unzip with `ditto -x -k`, `codesign --verify --deep --strict`, atomic swap of `/Applications/YT4S.app` via a tiny detached helper after the app quits, relaunch with `open`. ~150-300 lines; you own edge cases. |
| "Download new DMG in browser" link | Rejected: browser download is quarantined, so Sarah hits Open Anyway on every update. |

## Recommendation

- Self-update via in-app download is viable and keeps Sarah prompt-free after first install.
- If the stack is Swift: use Sparkle 2 with EdDSA, ad-hoc signing, Hardened Runtime off, appcast at `releases/latest/download/appcast.xml`.
- If the stack is Python or other: hand-roll the updater per the table, with ed25519 signature verification (key pinned in the app) rather than SHA-256 alone, since without Developer ID the signature is the only defense against a tampered asset.
- Never set `LSFileQuarantineEnabled`; never route updates through the browser.
- First install: ship a DMG with an Applications alias; Nick walks Sarah through Open Anyway once (or installs it himself via `curl` in Terminal on her Mac, which skips quarantine entirely).

## First-install friction that remains

- One Gatekeeper block on first launch, then System Settings > Privacy & Security > Open Anyway + password (macOS 15+), within about an hour of the block.
- Must be in `/Applications` before first launch to avoid translocation.
- Not removable without Developer ID + notarization (out of scope).

## Open risks (verify in a spike before locking the ADR)

- Undocumented provenance/Gatekeeper behavior: confirm on a current macOS (15 and 26+) that an ad-hoc bundle written by the approved app launches with no prompt after replacement, and that the "exception" from Open Anyway is not needed again.
- Confirm Apple's "may run Gatekeeper at other times" does not bite a changed cdhash on each release.
