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
  <img src="docs/screenshots/cover-select.png" height="380" alt="Cover selection — candidates with online previews">
</p>

<p align="center"><sub><b>Status</b> · <b>Setup</b> · <b>Cover selection</b></sub></p>

## Installation (recommended path — DMG)

1. Download `fb2-to-epub-<version>.dmg` from the **[Releases](https://github.com/ArrivaRUS/fb2-to-epub/releases)** page.
2. Open the `.dmg` and drag the **fb2-to-epub** app into the **Applications** folder — the arrow on the window background shows where it goes.
3. **First launch** (one time only): open the Applications folder, **right-click** `fb2-to-epub` → **Open** → confirm **Open** in the dialog.
   *Alternative:* launch the app, then go to **System Settings → Privacy & Security → Open Anyway**.
   The app is built without a paid Apple signing certificate, so macOS asks for confirmation — this is a one-time step, after which it launches with a normal double-click.
4. The app checks that **Calibre** is installed (if not, it offers to open the download page), then prompts you to **choose a folder** to watch. The default is `~/Desktop/fb2-to-epub` (created automatically).
5. Done. A screen appears showing the chosen folder and an **Open Folder** button.

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

The access is bound to this specific file and persists across app updates. The installer prints the exact runner path at the end of installation.

> Why the runner specifically: macOS binds file-access permissions not to the script but to the executable named in the agent's `ProgramArguments`. This gives the agent a stable "responsible" target at a fixed path (`fb2-to-epub-runner.sh`) that you can grant access to once.

## Requirements

- **macOS** (11.0+).
- **[Calibre](https://calibre-ebook.com)** — requires `/Applications/calibre.app/Contents/MacOS/ebook-convert` and `ebook-meta`.
  Install with `brew install --cask calibre` or [download it from the website](https://calibre-ebook.com/download_osx).
- **`python3`** — included with the Xcode Command Line Tools (`xcode-select --install`). Used only for cover lookups, with no third-party dependencies.

## How it works

- macOS `launchd` watches the chosen folder via `WatchPaths`. Agent: `com.arrivarus.fb2toepub.agent`.
- When new files appear, the agent runs the **runner** (`fb2-to-epub-runner.sh`, the FDA target), which exec's the **watcher** (`fb2-to-epub-watcher.sh`).
- The watcher converts books through [Calibre](https://calibre-ebook.com) (`ebook-convert`, `ebook-meta`).
- Cover lookups are handled by `fb2-to-epub-cover-finder.py` (Python 3, no third-party dependencies).
- The absolute paths to `ebook-convert` and `python3` are passed to the agent via `EnvironmentVariables` (the agent starts with a bare `PATH`).
- `ThrottleInterval=5s` smooths out batch copying; a lock directory in `/tmp` serializes parallel runs.

The scripts live in `~/Library/Application Support/fb2-to-epub/bin/`, the agent config is at `~/Library/LaunchAgents/com.arrivarus.fb2toepub.agent.plist`, and the log is at `~/Library/Logs/fb2-to-epub.log`.

## Managing it

| Action | Command |
| --- | --- |
| Live logs | `tail -f ~/Library/Logs/fb2-to-epub.log` |
| Stop the agent | `launchctl bootout gui/$(id -u)/com.arrivarus.fb2toepub.agent` |
| Start the agent | `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.arrivarus.fb2toepub.agent.plist` |
| Restart / run manually | `launchctl kickstart -k gui/$(id -u)/com.arrivarus.fb2toepub.agent` |
| Change the watched folder | Launch the **fb2-to-epub** app again and pick a new folder (reinstalling is idempotent) |
| Uninstall | Use `./uninstall.sh` from the repository (CLI path below) |

## Cover handling

- If the FB2 has an embedded cover, Calibre uses it.
- If there is no cover, the script looks one up online by title + author. Sources:
  1. [Open Library](https://openlibrary.org) — a catalog API; fast and reliable, but thin on Russian editions.
  2. [DuckDuckGo Images](https://duckduckgo.com) — a broad image search; for Russian queries it reliably pulls covers from labirint.ru, ozon.ru, knijky.ru, and similar sites.

  Results from the two sources are merged and checked one by one. A candidate is accepted only if the downloaded image looks like a cover: an aspect ratio in the 1.0–2.5 range (height/width) and a width of at least 200 px. This filters out author photos, thumbnails, and square logos.
- **Multiple good matches → pick in the app.** If **two or more** suitable covers are found, the best one is applied right away (without delaying the conversion) and the book is added to the **"Choose cover"** queue in the app window. There you can open the queue, view the found candidates with previews, and **pick a different one** — the chosen cover is then **rewritten into the already-built `.epub`** (done by the background agent via Calibre). You can keep the auto pick or skip it. It all happens in the window, with no pop-ups interrupting your work.
- If the internet is unavailable or nothing suitable is found, the EPUB is built without a cover (Calibre's default gray placeholder is suppressed with the `--no-default-epub-cover` flag).

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

Artifacts (`*.app`, `*.dmg`, `build/dist/`) are in `.gitignore` — binaries are not committed, and the `.dmg` goes into a GitHub Release.

```sh
# 1. app: dist/fb2-to-epub.app (osacompile + icon + ad-hoc codesign)
build/build-app.sh [version]

# 2. DMG: build/dist/fb2-to-epub-<version>.dmg (+ .sha256)
brew install create-dmg            # requires Homebrew create-dmg (andreyvit)
build/make-dmg.sh [version]
```

`build-app.sh` builds the `.app` from the AppleScript applet (`packaging/applet.applescript`), places `installer.sh` + the watcher + the cover-finder + the runner into `Contents/Resources`, builds the icon from `branding/icon-app.svg` (full-bleed for macOS 26), and explicitly sets `CFBundleIdentifier=com.arrivarus.fb2toepub` (a stable id matters so that TCC grants don't get dropped on a rebuild). `make-dmg.sh` packages the `.app` + a `/Applications` symlink + a background with first-launch instructions.

## License

[MIT](LICENSE)
