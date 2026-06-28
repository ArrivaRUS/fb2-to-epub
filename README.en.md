# fb2-to-epub

[Русский](README.md) · **English**

<img src="branding/icon.png" alt="fb2-to-epub" width="96" align="right">

Automatic **FB2 → EPUB** conversion on macOS for a folder of your choice. Install the app, point it at a folder, and from then on you just drop `.fb2` / `.fb2.zip` files or whole book folders into it, and finished `.epub` files appear right next to them. Installation and status live in a tidy native window; the conversion itself runs in the background, with no manual runs.

## Interface

<p align="center">
  <img src="docs/screenshots/status.png" height="380" alt="Status screen — watching, stats, recent conversions">
  &nbsp;&nbsp;
  <img src="docs/screenshots/setup.png" height="380" alt="Setup screen — Calibre check and folder selection">
  &nbsp;&nbsp;
  <img src="docs/screenshots/settings.png" height="380" alt="Settings — reset stats, Full Disk Access, check for updates">
  &nbsp;&nbsp;
  <img src="docs/screenshots/cover-select.png" height="380" alt="Cover selection — online candidates with previews and generated fallbacks">
</p>

<p align="center"><sub><b>Status</b> · <b>Setup</b> · <b>Settings</b> · <b>Cover selection</b></sub></p>

The app is native (SwiftUI), with a fixed-width 400px window and a dark theme. Four screens: **Setup** (first run), **Status**, **Settings**, and **Cover selection**.

## Features

- **Folder-based auto-conversion.** Point it at a single folder — the background agent catches new files and converts them on its own, with no manual runs. A single `*.fb2` / `*.fb2.zip` file → an `.epub` appears next to it; a book folder (any nesting depth) → a mirror folder with the `-epub` suffix is created next to it. Source files are left untouched, and repeated runs are idempotent (anything already up to date is skipped).
- **Live status.** A progress ring fills clockwise as a batch converts and shows 100% once everything is done (its center shows a "done / total" counter while a batch is running). Next to it: "total" and "today" counters, the Calibre version, the background agent's status (running / paused), the watched folder, a list of recent conversions, and an **Open Folder** button. Everything updates event-driven — no manual refresh.
- **Auto bring-to-front.** When a new conversion batch starts, the window comes to the front on its own, so you can see the process kick off.
- **Built-in auto-update.** **⚙ Settings → Check for updates** downloads and installs the new version of the app; the background agent is updated automatically along with it.
- **Settings screen.** Reset statistics · Full Disk Access · app version + Check for updates. Authorship and a GitHub link sit at the bottom of the screen.
- **Reset statistics.** Clears "total", "today", and the recent-conversions list (it does not touch the `.epub` files themselves).
- **Smart covers.** If the FB2 has no cover, the app looks one up online, lets you pick from the matches, guards against the wrong cover by title, and — if nothing suitable is found online — draws a nice typographic cover itself (details in the [Cover handling](#cover-handling) section).

## Installation (recommended path — DMG)

1. Download `fb2-to-epub-<version>.dmg` from the **[Releases](https://github.com/ArrivaRUS/fb2-to-epub/releases)** page.
2. Open the `.dmg` and drag the **fb2-to-epub** app into the **Applications** folder — the arrow on the window background shows where it goes.
3. **First launch** (one time only): open the Applications folder, **right-click** `fb2-to-epub` → **Open** → confirm **Open** in the dialog.
   *Alternative:* launch the app, then go to **System Settings → Privacy & Security → Open Anyway**.
   The app is built without a paid Apple signing certificate, so macOS asks for confirmation — this is a one-time step, after which it launches with a normal double-click.
4. The app checks that **Calibre** is installed (if not, it offers to open the download page), then prompts you to **choose a folder** to watch. The default is `~/Desktop/fb2-to-epub` (created automatically).
5. Done. A "Ready to go" screen appears showing the chosen folder and an **Open Folder** button.

From now on, drop into the chosen folder:

- a **single file** `*.fb2` or `*.fb2.zip` → a file with the same name and an `.epub` extension appears next to it;
- a **book folder** (any nesting depth) → a mirror folder with the `-epub` suffix is created next to it, reproducing the subdirectory structure with the finished `.epub` files.

Source files are left untouched. Repeated runs are idempotent — already-converted books are skipped (an `.epub` is considered up to date if it is newer than its source).

## Full Disk Access (if the folder is in Desktop / Documents / Downloads)

`~/Desktop`, `~/Documents`, and `~/Downloads` are macOS-protected zones (TCC). On a fresh Mac, the background agent may need **one-time** access to them. If files stop converting (or never start) — grant Full Disk Access to the **runner**:

1. **System Settings → Privacy & Security → Full Disk Access**.
2. Click **+**, then in the picker press **Cmd-Shift-G** and paste the path:
   ```
   ~/Library/Application Support/fb2-to-epub/bin/fb2-to-epub-runner.sh
   ```
3. Add it and **turn the toggle on**.

The access is bound to this specific file and persists across app updates. The installer prints the exact runner path at the end of installation. There is also a quick jump to the right pane inside the app: **⚙ Settings → Full Disk Access**.

> Why the runner specifically: macOS binds file-access permissions not to the script but to the executable named in the agent's `ProgramArguments`. This gives the agent a stable "responsible" target at a fixed path (`fb2-to-epub-runner.sh`) that you can grant access to once.

## Requirements

- **macOS** (11.0+).
- **[Calibre](https://calibre-ebook.com)** — requires `/Applications/calibre.app/Contents/MacOS/ebook-convert` and `ebook-meta`.
  Install with `brew install --cask calibre` or [download it from the website](https://calibre-ebook.com/download_osx).
- **`python3`** — included with the Xcode Command Line Tools (`xcode-select --install`). Used only for online cover lookups, with no third-party dependencies.

## Cover handling

The app tries to give every book a cover — without ever sticking the wrong one on it.

- **Embedded cover.** If the FB2 already has a cover, Calibre uses it, with no lookup.
- **Online lookup.** If there is no cover, the app looks one up online by author + title. Sources:
  1. [Open Library](https://openlibrary.org) — a catalog API; fast and reliable, but thin on Russian editions.
  2. [DuckDuckGo Images](https://duckduckgo.com) — a broad image search; for Russian queries it reliably pulls covers from labirint.ru, ozon.ru, knijky.ru, and similar sites.

  Results from the two sources are merged and filtered **by shape**: a candidate is accepted only if the image looks like a cover — an aspect ratio in the 1.0–2.5 range (height/width) and a width of at least 200 px. This filters out author photos, thumbnails, and square logos.
- **Multiple good matches → pick in the app.** If several suitable covers are found, the book is added to the **"Choose cover"** queue. On the Cover selection screen you see the candidates with previews and a pager — you can flip through and **pick** the one you want; the chosen cover is then **embedded into the already-built `.epub`** by the background agent (via Calibre).
- **Guard against the wrong cover (title-match).** The agent **does not embed automatically** a cover whose title doesn't match the book — so it won't accidentally glue on someone else's image. In that case it offers you to pick a cover by hand from the matches, or use a generated one.
- **"Search more" with a hint.** If none of the found options fits, click **Search more** — a dialog with a field opens (author + book title). The app runs a new search **for your query**, excluding the options already shown.
- **Generated fallback covers.** When nothing suitable is found online, the app **draws 4 clean typographic covers itself** (author's last name + title) from ready-made templates — you pick one. This is a native render from built-in templates, **with no generative AI and no third-party dependencies**.
- If the internet is unavailable and no cover ends up being chosen, the EPUB is left without a cover (Calibre's default gray placeholder is suppressed with the `--no-default-epub-cover` flag).

## Managing it

| Action | Command |
| --- | --- |
| Live logs | `tail -f ~/Library/Logs/fb2-to-epub.log` |
| Stop the agent | `launchctl bootout gui/$(id -u)/com.arrivarus.fb2toepub.agent` |
| Start the agent | `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.arrivarus.fb2toepub.agent.plist` |
| Restart / run manually | `launchctl kickstart -k gui/$(id -u)/com.arrivarus.fb2toepub.agent` |
| Change the watched folder | Click **Change** on the Status screen (or launch the app again) and pick a new folder — reinstalling is idempotent |
| Uninstall | Use `./uninstall.sh` from the repository (CLI path below) |

## How it works

- macOS `launchd` watches the chosen folder via `WatchPaths`. Agent: `com.arrivarus.fb2toepub.agent`.
- When new files appear, the agent runs the **runner** (`fb2-to-epub-runner.sh`, the FDA target), which exec's the **watcher** (`fb2-to-epub-watcher.sh`).
- The watcher converts books through [Calibre](https://calibre-ebook.com) (`ebook-convert`, `ebook-meta`).
- Cover lookups are handled by `fb2-to-epub-cover-finder.py` (Python 3, no third-party dependencies). Fallback covers are rendered by the app itself, natively (no Python).
- The app and the agent communicate through state files: the agent writes `state.json` atomically (batch progress, statistics, the cover queue), and the app reads it and reacts event-driven.
- The absolute paths to `ebook-convert` and `python3` are passed to the agent via `EnvironmentVariables` (the agent starts with a bare `PATH`).
- `ThrottleInterval=5s` smooths out batch copying; a lock directory in `/tmp` serializes parallel runs.

The scripts live in `~/Library/Application Support/fb2-to-epub/bin/`, the data (state, the cover queue, and previews) lives in `~/Library/Application Support/fb2-to-epub/`, the agent config is at `~/Library/LaunchAgents/com.arrivarus.fb2toepub.agent.plist`, and the log is at `~/Library/Logs/fb2-to-epub.log`.

## Advanced path — install from the CLI

For developers and anyone who prefers the terminal. This bypasses the app and the DMG — it installs the same agent with the same installer (`packaging/installer.sh`).

```sh
# 1. Calibre (if you don't have it yet)
brew install --cask calibre

# 2. Clone and install
git clone https://github.com/ArrivaRUS/fb2-to-epub.git
cd fb2-to-epub
./install.sh                       # default folder ~/Desktop/fb2-to-epub
./install.sh "/path/to/my folder"  # or your own folder
```

To uninstall: `./uninstall.sh` (removes the agent and deletes the installation from App Support; the chosen folder and the converted files are left in place).

## Building from source

The app is **native** — `build-app.sh` compiles the Swift sources (SwiftUI / AppKit / Foundation, no third-party dependencies) rather than building an AppleScript applet. Artifacts (`*.app`, `*.dmg`, `build/dist/`) are in `.gitignore` — binaries are not committed, and the `.dmg` goes into a GitHub Release.

```sh
# 1. app: build/dist/fb2-to-epub.app
#    (compiles Swift into a universal arm64+x86_64 binary + icon + ad-hoc codesign)
build/build-app.sh [version]

# 2. DMG: build/dist/fb2-to-epub-<version>.dmg (+ .sha256)
brew install create-dmg            # requires Homebrew create-dmg (andreyvit)
build/make-dmg.sh [version]
```

`build-app.sh`:

- compiles `app/*.swift` (`main.swift`, `StatusView`, `SetupView`, `CoverSelectView`, `SettingsView`, `CoverGenerator`, `UpdateChecker`, and others) with `xcrun swiftc` for **arm64 and x86_64** and joins them into a universal binary (`lipo`);
- places the agent scripts — `installer.sh`, `fb2-to-epub-runner.sh`, the watcher, and the cover-finder — into `Contents/Resources`;
- bundles the 4 cover templates (`cover-templates/`) and the icon (from `branding/icon-app.svg` → `.icns`);
- writes a clean `Info.plist` with a fixed `CFBundleIdentifier=com.arrivarus.fb2toepub` (a stable id matters so that TCC grants don't get dropped on a rebuild);
- runs an ad-hoc `codesign` with a strict verify (with retries against the FinderInfo race in iCloud-synced folders).

`make-dmg.sh` packages the `.app` + a `/Applications` symlink + a background with first-launch instructions.

## License

[MIT](LICENSE)
