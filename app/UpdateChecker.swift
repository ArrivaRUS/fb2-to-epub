// fb2-to-epub — update checker (v0.2.2).
//
// PART 1: ask the GitHub "latest release" API which version is published and
// whether it is newer than the running build (`checkLatest` → `UpdateInfo`).
//
// PART 2 (this file, below `MARK: - Download + install`): download the .dmg,
// verify its sha256, then hand off to a detached shell script that — AFTER the
// app quits — mounts the dmg, atomically replaces the running bundle in place,
// strips quarantine, and relaunches. Any failure before the hand-off surfaces
// as `.failure` so the caller can fall back to opening the releases page.
//
// SECURITY INVARIANT: the install target is ALWAYS the running bundle
// (`Bundle.main.bundlePath`), never a hardcoded /Applications. A test copy run
// from build/dist therefore updates *itself*, not a real install.

import Foundation
import CryptoKit
import AppKit   // NSApp.terminate after the installer hand-off

enum UpdateChecker {

    // MARK: - Current build version

    /// The running app's marketing version (CFBundleShortVersionString), e.g.
    /// "0.2.2". Falls back to "0" when the key is absent (dev/CLI runs) so semver
    /// comparison still has a valid operand.
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // MARK: - Result model

    /// What the latest-release lookup found.
    struct UpdateInfo {
        /// Latest published version, leading "v" stripped (e.g. "0.2.3").
        let latestVersion: String
        /// Direct download URL of the release's .dmg asset, if present. Consumed by
        /// `downloadAndInstall` (part 2); the sha256 sidecar is fetched from the
        /// same URL with a ".sha256" suffix.
        let dmgURL: URL?
        /// True when `latestVersion` is strictly newer than `currentVersion`.
        let isNewer: Bool
    }

    // MARK: - Semver compare

    /// Strict "is `latest` a newer version than `current`?" by numeric, per-component
    /// comparison. Both strings are split on "." and compared component-by-component
    /// as integers; missing trailing components count as 0 ("1.0" == "1.0.0").
    /// Non-numeric components degrade to 0. Returns true only when `latest` > `current`.
    ///
    /// Examples (all hold):
    ///   isNewer("0.2.2",  than: "0.2.1") == true
    ///   isNewer("0.2.1",  than: "0.2.1") == false
    ///   isNewer("0.10.0", than: "0.9.9") == true
    ///   isNewer("1.0",    than: "0.9.9") == true
    static func isNewer(_ latest: String, than current: String) -> Bool {
        let lhs = latest.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = current.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(lhs.count, rhs.count)
        for i in 0..<count {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r { return l > r }
        }
        return false // all components equal -> not newer
    }

    // MARK: - Network lookup

    /// GitHub "latest release" endpoint for this repo.
    private static let latestReleaseURL =
        "https://api.github.com/repos/ArrivaRUS/fb2-to-epub/releases/latest"

    /// Errors surfaced when the lookup can't produce an `UpdateInfo`.
    private enum CheckError: LocalizedError {
        case badResponse
        case badPayload

        var errorDescription: String? {
            switch self {
            case .badResponse: return "Сервер вернул неожиданный ответ."
            case .badPayload:  return "Не удалось разобрать ответ сервера."
            }
        }
    }

    /// Fetch the latest published release and report whether it's newer than the
    /// running build. Network/parse failures arrive as `.failure`.
    ///
    /// IMPORTANT: GitHub rejects requests WITHOUT a User-Agent header (HTTP 403),
    /// so we always send one. `completion` may be called on a background thread —
    /// the caller is responsible for hopping to the main thread before touching UI.
    static func checkLatest(completion: @escaping (Result<UpdateInfo, Error>) -> Void) {
        guard let url = URL(string: latestReleaseURL) else {
            completion(.failure(CheckError.badResponse))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // GitHub returns 403 without a UA; the Accept header pins the v3 JSON shape.
        request.setValue("fb2-to-epub", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard
                let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode)
            else {
                completion(.failure(CheckError.badResponse))
                return
            }
            guard let data = data else {
                completion(.failure(CheckError.badPayload))
                return
            }

            do {
                let info = try parseRelease(data)
                completion(.success(info))
            } catch {
                completion(.failure(error))
            }
        }
        task.resume()
    }

    /// Parse a GitHub "release" JSON object into `UpdateInfo`:
    ///   - `tag_name` -> latestVersion (a single leading "v" is stripped),
    ///   - the first `assets[]` entry whose `name` ends in ".dmg" -> dmgURL
    ///     (from its `browser_download_url`).
    /// Throws `CheckError.badPayload` when the JSON isn't an object or lacks tag_name.
    private static func parseRelease(_ data: Data) throws -> UpdateInfo {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tag = root["tag_name"] as? String
        else {
            throw CheckError.badPayload
        }

        // Strip exactly one leading "v" (e.g. "v0.2.3" -> "0.2.3").
        let latestVersion = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag

        var dmgURL: URL?
        if let assets = root["assets"] as? [[String: Any]] {
            for asset in assets {
                guard let name = asset["name"] as? String,
                      name.lowercased().hasSuffix(".dmg"),
                      let urlString = asset["browser_download_url"] as? String,
                      let assetURL = URL(string: urlString)
                else { continue }
                dmgURL = assetURL
                break
            }
        }

        let newer = isNewer(latestVersion, than: currentVersion)
        return UpdateInfo(latestVersion: latestVersion, dmgURL: dmgURL, isNewer: newer)
    }

    // MARK: - Download + install (part 2)

    /// Errors raised by the download/verify/install path. All of them mean
    /// "auto-update failed" → the caller falls back to the releases page.
    enum InstallError: LocalizedError {
        case noDMG                         // the release had no .dmg asset
        case untrustedSource               // dmg/.sha256 URL not https on an allowed host
        case downloadFailed                // dmg or .sha256 GET failed / non-2xx
        case checksumUnreadable            // .sha256 sidecar couldn't be parsed
        case checksumMismatch(expected: String, got: String)
        case scriptWriteFailed             // couldn't write/chmod the install script
        case launchFailed                  // couldn't spawn the detached installer

        var errorDescription: String? {
            switch self {
            case .noDMG:              return "В релизе нет .dmg для автоматической установки."
            case .untrustedSource:    return "Источник обновления не прошёл проверку безопасности."
            case .downloadFailed:     return "Не удалось скачать обновление."
            case .checksumUnreadable: return "Не удалось прочитать контрольную сумму."
            case .checksumMismatch:   return "Контрольная сумма не совпала — файл повреждён."
            case .scriptWriteFailed:  return "Не удалось подготовить установщик."
            case .launchFailed:       return "Не удалось запустить установщик."
            }
        }
    }

    /// Whether `url` is a safe place to fetch an update artifact from: scheme MUST
    /// be https AND the host MUST be a GitHub release origin. This blocks an http
    /// downgrade and a swap to an attacker-controlled host even if the JSON the API
    /// returned were tampered with. Allowed hosts: `github.com`,
    /// `objects.githubusercontent.com`, or anything under `.githubusercontent.com`.
    static func isTrustedSource(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased()
        else { return false }
        return host == "github.com"
            || host == "objects.githubusercontent.com"
            || host.hasSuffix(".githubusercontent.com")
    }

    /// A fresh private working directory under /tmp for this update run (the dmg and
    /// the generated installer script live here). /tmp so they survive the app
    /// quitting (NSTemporaryDirectory is per-app and may be cleared on terminate);
    /// a unique mktemp-style dir avoids fixed-name clobbering/symlink races. The
    /// installer script removes this whole directory when it finishes.
    /// Returns nil if the directory can't be created.
    private static func makeWorkDir() -> URL? {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("fb2-to-epub-update-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            return dir
        } catch {
            return nil
        }
    }

    /// Download `info.dmgURL`, verify it against its `<dmg>.sha256` sidecar, then
    /// kick off the detached installer and quit the app. On any failure BEFORE the
    /// hand-off, `completion(.failure)` is called and the app stays running.
    ///
    /// `completion` may run on a background thread — the caller hops to main for UI.
    /// On SUCCESS the installer has been launched and `NSApp.terminate` requested;
    /// `completion` is NOT called in that case (the process is on its way out).
    static func downloadAndInstall(
        _ info: UpdateInfo,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let dmgURL = info.dmgURL else {
            completion(.failure(InstallError.noDMG))
            return
        }
        // sha256 sidecar lives next to the dmg: "<dmg>.sha256". Build it explicitly
        // from the absolute string — appendingPathExtension mangles URLs with a query.
        guard let shaURL = URL(string: dmgURL.absoluteString + ".sha256") else {
            completion(.failure(InstallError.downloadFailed))
            return
        }
        // Refuse anything that isn't https on a GitHub release origin (downgrade /
        // host-swap defense), for BOTH the dmg and its checksum sidecar.
        guard isTrustedSource(dmgURL), isTrustedSource(shaURL) else {
            completion(.failure(InstallError.untrustedSource))
            return
        }
        // Stage everything in a fresh private dir the installer cleans up at the end.
        guard let workDir = makeWorkDir() else {
            completion(.failure(InstallError.scriptWriteFailed))
            return
        }
        let dmgDest = workDir.appendingPathComponent(
            "fb2-to-epub-update-\(info.latestVersion).dmg")

        // 1) download the dmg.
        downloadFile(from: dmgURL, to: dmgDest) { dmgResult in
            switch dmgResult {
            case .failure:
                completion(.failure(InstallError.downloadFailed))
            case .success:
                // 2) download + parse the checksum sidecar.
                fetchData(shaURL) { shaResult in
                    switch shaResult {
                    case .failure:
                        completion(.failure(InstallError.downloadFailed))
                    case .success(let shaData):
                        guard let expected = parseSHA256(shaData) else {
                            completion(.failure(InstallError.checksumUnreadable))
                            return
                        }
                        // 3) hash the local file and compare.
                        guard let actual = sha256Hex(ofFileAt: dmgDest) else {
                            completion(.failure(InstallError.downloadFailed))
                            return
                        }
                        guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                            try? FileManager.default.removeItem(at: dmgDest)
                            completion(.failure(
                                InstallError.checksumMismatch(expected: expected, got: actual)))
                            return
                        }
                        // 4) verified → write the script, launch detached, quit.
                        do {
                            try launchInstaller(dmgPath: dmgDest.path, workDir: workDir)
                            // Hand-off done; the script owns the rest. No completion.
                        } catch {
                            completion(.failure(error))
                        }
                    }
                }
            }
        }
    }

    // MARK: Download helpers

    /// Download `url` to `dest` (overwriting). Failure on transport error or non-2xx.
    private static func downloadFile(
        from url: URL,
        to dest: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        var request = URLRequest(url: url)
        request.setValue("fb2-to-epub", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120

        let task = URLSession.shared.downloadTask(with: request) { tmpURL, response, error in
            if let error = error { completion(.failure(error)); return }
            guard
                let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode),
                let tmpURL = tmpURL
            else { completion(.failure(InstallError.downloadFailed)); return }
            do {
                let fm = FileManager.default
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.moveItem(at: tmpURL, to: dest)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
        task.resume()
    }

    /// GET small data (the .sha256 sidecar). Failure on transport error or non-2xx.
    private static func fetchData(
        _ url: URL,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        var request = URLRequest(url: url)
        request.setValue("fb2-to-epub", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error { completion(.failure(error)); return }
            guard
                let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode),
                let data = data
            else { completion(.failure(InstallError.downloadFailed)); return }
            completion(.success(data))
        }
        task.resume()
    }

    /// Parse a `shasum -a 256` sidecar: "<hex>  <filename>". Returns the lowercased
    /// hex digest (the first whitespace-delimited token), or nil if it isn't a
    /// plausible 64-char hex string.
    static func parseSHA256(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard let first = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0.isNewline }).first
        else { return nil }
        let hex = String(first).lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hex
    }

    /// Streamed SHA-256 of a file (CryptoKit), as lowercase hex. nil on read error.
    /// Streamed so a large dmg isn't loaded into memory at once.
    static func sha256Hex(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20) // 1 MiB
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Install hand-off

    /// Write the detached installer script, make it executable, spawn it so it
    /// outlives this process, then ask the app to quit.
    ///
    /// The script is parameterized — `$1=dmgPath $2=targetAppPath $3=appPID
    /// $4=workDir` — so a tester can run it standalone against an arbitrary copy. The
    /// target app is the RUNNING bundle (`Bundle.main.bundlePath`), never a hardcoded
    /// /Applications. `workDir` is the private staging dir the script deletes at the end.
    private static func launchInstaller(dmgPath: String, workDir: URL) throws {
        let scriptPath = workDir.appendingPathComponent("install.sh").path
        do {
            try installScriptBody.write(
                toFile: scriptPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        } catch {
            throw InstallError.scriptWriteFailed
        }

        let targetApp = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier

        // Spawn detached: `nohup <script> ... >/dev/null 2>&1 &` via /bin/sh, so the
        // installer survives the parent's exit (no setsid on macOS). The script's
        // first act is to wait on the parent PID, so it can't race ahead of the quit.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "nohup \(shellQuote(scriptPath)) "
                + "\(shellQuote(dmgPath)) "
                + "\(shellQuote(targetApp)) "
                + "\(pid) "
                + "\(shellQuote(workDir.path)) >/dev/null 2>&1 &",
        ]
        do {
            try process.run()
        } catch {
            throw InstallError.launchFailed
        }

        // Quit so the script can replace the bundle. Main thread for AppKit.
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    /// Single-quote a string for safe interpolation into a /bin/sh command line.
    /// Wraps in '…' and escapes embedded single quotes as '\''.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The installer shell script, run AFTER the app quits with `$1 dmgPath`,
    /// `$2 targetAppPath`, `$3 appPID`, `$4 workDir`. Self-contained and idempotent
    /// enough to be run standalone by a tester against a throwaway copy.
    ///
    /// Safety: it NEVER deletes the old bundle until the new one is staged next to
    /// it, and after removing the old bundle it VERIFIES the path is gone before the
    /// final `mv` — so it can never nest the new app inside the old one. On any
    /// failure it relaunches the bundle still at `$2`, so the user is never stranded.
    private static let installScriptBody = #"""
    #!/bin/sh
    # fb2-to-epub auto-updater (part 2). Args:
    #   $1 = path to the downloaded .dmg
    #   $2 = target .app bundle to replace (the previously-running bundle)
    #   $3 = PID of the app to wait for before touching its bundle
    #   $4 = private working directory to delete on exit (optional; the dmg + this
    #        script live in it). Empty when run standalone by a tester.
    #
    # Standalone-testable: pass a throwaway dmg/app/pid. Hardcodes nothing.
    set -u

    DMG="$1"
    TARGET="$2"
    APP_PID="$3"
    WORKDIR="${4:-}"
    APP_NAME="fb2-to-epub.app"

    log() { printf '[fb2-update] %s\n' "$1" >&2; }

    # Always try to relaunch SOMETHING at the target so the user isn't stranded.
    relaunch() { [ -d "$TARGET" ] && open "$TARGET" >/dev/null 2>&1 || true; }

    # 1) wait for the app to quit (bounded ~30s so we never hang forever).
    i=0
    while kill -0 "$APP_PID" 2>/dev/null; do
      sleep 0.3
      i=$((i + 1))
      [ "$i" -ge 100 ] && { log "timeout waiting for pid $APP_PID"; break; }
    done

    # 2) mount the dmg on a private mountpoint.
    MNT="$(mktemp -d /tmp/fb2-update-mnt.XXXXXX)" || { log "mktemp failed"; relaunch; exit 1; }
    if ! hdiutil attach "$DMG" -nobrowse -mountpoint "$MNT" >/dev/null 2>&1; then
      log "hdiutil attach failed"
      rmdir "$MNT" 2>/dev/null || true
      relaunch
      exit 1
    fi

    cleanup() {
      hdiutil detach "$MNT" >/dev/null 2>&1 || hdiutil detach "$MNT" -force >/dev/null 2>&1 || true
      rmdir "$MNT" 2>/dev/null || true
      rm -f "$DMG" 2>/dev/null || true
      # Remove the private staging dir (holds the dmg + this very script). Guarded so
      # a standalone run without $4 never rm -rf's something unexpected.
      [ -n "$WORKDIR" ] && rm -rf "$WORKDIR" 2>/dev/null || true
    }

    SRC="$MNT/$APP_NAME"
    if [ ! -d "$SRC" ]; then
      log "no $APP_NAME inside dmg"
      cleanup
      relaunch
      exit 1
    fi

    # 3) atomic-ish replace: stage "$TARGET.new" beside the target, then swap.
    #    mv within the same directory is atomic; we only rm the old AFTER the new
    #    copy succeeded, so a failed ditto leaves the working app untouched.
    NEW="$TARGET.new"
    rm -rf "$NEW" 2>/dev/null || true
    if ! ditto "$SRC" "$NEW"; then
      log "ditto failed — keeping existing app"
      rm -rf "$NEW" 2>/dev/null || true
      cleanup
      relaunch
      exit 1
    fi

    # Remove the old bundle, then VERIFY it's actually gone. If $TARGET still exists
    # (locked / no permission / open), a plain `mv "$NEW" "$TARGET"` would drop the
    # new bundle *inside* the old one (…/fb2-to-epub.app/fb2-to-epub.app) and the
    # script would falsely report success while the OLD app keeps running. So bail
    # out instead: discard the staged copy, clean the mount, relaunch the working
    # old app. Invariant: either the new bundle replaces it wholesale, or the old
    # working one stays — NEVER a nested app/app.
    rm -rf "$TARGET" 2>/dev/null || true
    if [ -e "$TARGET" ]; then
      log "could not remove old bundle — keeping existing app"
      rm -rf "$NEW" 2>/dev/null || true
      cleanup
      relaunch
      exit 1
    fi

    if ! mv "$NEW" "$TARGET"; then
      log "mv failed after removing old bundle"
      # $TARGET is gone (rm above succeeded); try once more to seat the staged copy.
      mv "$NEW" "$TARGET" 2>/dev/null || true
      cleanup
      relaunch
      exit 1
    fi

    # 4) unsigned build: drop quarantine so it launches without the right-click dance.
    xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

    # 5) tidy up + relaunch the freshly installed app.
    cleanup
    open "$TARGET" >/dev/null 2>&1 || true
    exit 0
    """#
}
