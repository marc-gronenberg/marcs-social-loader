# Marc's Social Loader

Native macOS app to download videos from YouTube, Instagram, TikTok, X and
other platforms. Written in Swift/SwiftUI, wraps `yt-dlp` and `ffmpeg`.

Free software under the **GNU GPL v3**. Ships as a self-contained `.app`
bundle with all dependencies included — no Homebrew, no terminal, no
package manager.

## Features

- Paste a URL → thumbnail, title, duration and available qualities fetched
  in the background
- Per-video quality picker (prefers H.264/AAC for Adobe Media Encoder
  compatibility)
- Parallel downloads (up to 3 at once) with cumulative per-item progress bar
- Dock-tile progress overlay like Adobe Media Encoder
- Custom filename per video (double-click to rename)
- Native macOS notification on completion → click to reveal in Finder
- 9 languages with automatic system language detection
- Light / Dark / System appearance, with runtime icon swap
- Automatic updates via Sparkle

## Install

1. Download the latest `Marcs-Social-Loader-X.Y.Z.zip` from the
   [Releases page](../../releases)
2. Unzip and drag **Marc's Social Loader.app** to `/Applications`
3. First launch: because the app isn't signed with a paid Apple Developer
   ID, macOS will refuse to open it with a *"cannot verify developer"*
   warning. To open it anyway, **right-click the app** → **Open** →
   **Open** in the dialog. You only have to do this once.

After the first launch, updates are installed silently via Sparkle — no
more warnings.

## Build from source

```bash
git clone https://github.com/marc-gronenberg/marcs-social-loader.git
cd <repo>
./build.sh
open "dist/Marc's Social Loader.app"
```

First build downloads `yt-dlp` (~37 MB) and `ffmpeg` (~80 MB) into
`Resources/bin/` — those are cached afterwards. Final `.app` is ~120 MB.

## Releasing updates

The `release.sh` script automates the entire release pipeline. One command
bumps the version, builds, signs, uploads to GitHub Releases, and updates
the Sparkle appcast.

### One-time setup

1. **Install GitHub CLI and sign in:**
   ```bash
   brew install gh
   gh auth login
   ```

2. **Install Sparkle tools** (the SPM dependency doesn't include them):
   - Download the latest Sparkle release from
     https://github.com/sparkle-project/Sparkle/releases
   - Extract and copy `bin/generate_keys`, `bin/sign_update`, and
     `bin/generate_appcast` into `~/bin/` (make sure `~/bin` is on your
     `PATH`)

3. **Generate your EdDSA key pair** (once, ever):
   ```bash
   generate_keys
   ```
   The private key is stored in your **macOS Keychain**. The public key is
   printed to stdout — paste it into `Resources/Info.plist`:
   ```xml
   <key>SUPublicEDKey</key>
   <string>…your public key here…</string>
   ```
   **Back up your Keychain**. If you lose the private key, all existing
   installations will reject any future updates as forged.

4. **Enable GitHub Pages** for your repo:
   - Settings → Pages → Source: `main` branch, `/docs` folder → Save
   - The appcast will be served at
     `https://<user>.github.io/<repo>/appcast.xml`

5. **Point Sparkle at the feed** in `Resources/Info.plist`:
   ```xml
   <key>SUFeedURL</key>
   <string>https://<user>.github.io/<repo>/appcast.xml</string>
   <key>SUEnableAutomaticChecks</key>
   <true/>
   ```

6. **Rebuild** so the new `Info.plist` is baked into the first shipping
   version:
   ```bash
   ./build.sh
   ```

### Publishing a new version

Every time you want to ship an update:

```bash
./release.sh 1.1.0 --notes "Added French and Luxembourgish translations"
```

or with a file-based changelog:

```bash
./release.sh 1.1.0 --notes-file CHANGELOG-1.1.0.md
```

What happens behind the scenes:

1. Working tree is verified clean (no uncommitted changes)
2. `CFBundleShortVersionString` bumped to `1.1.0`, `CFBundleVersion`
   incremented by 1
3. `./build.sh` runs
4. The `.app` is zipped with `ditto` (preserves code signatures)
5. A git tag `v1.1.0` is created and pushed
6. A GitHub release is created via `gh` and the zip uploaded as an asset
7. The zip is signed with your EdDSA private key via `sign_update`
8. A new `<item>` is inserted into `docs/appcast.xml` with the download
   URL, signature, and release notes
9. `Info.plist` and `docs/appcast.xml` are committed and pushed to `main`
10. Users running an older version get the update within 24 hours — or
    immediately when they click **Nach Updates suchen…** in the app menu

### What users see when an update is available

Sparkle pops up its standard sheet with the new version number, release
notes, file size, and an **Install Update** button. Clicking it downloads
the zip in the background, verifies the EdDSA signature against the
public key baked into the installed app, replaces the `.app` in-place,
and relaunches. Zero user intervention beyond the one click.

Because Sparkle verifies with your EdDSA key (not with Apple's
notarization), updates work correctly on all Macs even though the app
isn't signed with a paid Developer ID.

## Project layout

```
.
├── Package.swift                 — SwiftPM manifest (declares Sparkle dep)
├── build.sh                      — builds the .app bundle
├── release.sh                    — one-command release pipeline
├── Resources/
│   ├── Info.plist                — app metadata + Sparkle config
│   ├── bin/                      — cached yt-dlp + ffmpeg (gitignored)
│   └── …icon source files…
├── Icon Exports/                 — master PNG icons (Default + Dark)
├── docs/                         — GitHub Pages root
│   └── appcast.xml               — Sparkle update feed
└── Sources/VideoDownloader/
    ├── main.swift                — NSApplication bootstrap + menu
    ├── ContentView.swift         — SwiftUI main window
    ├── VideoItemView.swift       — card view for each queued video
    ├── VideoItem.swift           — per-item @Observable model
    ├── DownloadManager.swift     — yt-dlp process orchestration
    ├── Metadata.swift            — --dump-json parsing
    ├── Config.swift              — JSON-backed settings
    ├── Localization.swift        — L10n system, 9 languages
    ├── SettingsView.swift        — settings window
    ├── AppearanceManager.swift   — Light/Dark/System
    ├── IconController.swift      — runtime Dock-icon swap
    ├── DockProgressView.swift    — custom Dock-tile progress bar
    ├── Notifications.swift       — DownloadNotifier / UNUser…Center
    └── UpdateController.swift    — Sparkle wrapper
```

## License

GPL v3. See `LICENSE`.

Bundled free software:

- [yt-dlp](https://github.com/yt-dlp/yt-dlp) — The Unlicense
- [ffmpeg](https://ffmpeg.org) — GPL v3 (build from evermeet.cx with GPL
  codecs enabled)
- [Sparkle](https://sparkle-project.org) — MIT License
