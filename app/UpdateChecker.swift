// fb2-to-epub — update checker (v0.2.2).
//
// PART 1: ask the GitHub "latest release" API which version is published and
// whether it is newer than the running build (`checkLatest` → `UpdateInfo`).
//
// PART 2 (this file, below `MARK: - Download + install`): download the .dmg to
// a temp file with a cheap size sanity-check, then hand off to a tiny detached
// bash script that — AFTER the app quits (its leading `sleep` covers the gap) —
// mounts the dmg, replaces the running bundle in place, strips quarantine, and
// relaunches. This mirrors the proven, minimal installer from the sibling
// "Claude Codex Limits" app: no checksum sidecar, no Application-Support
// staging, no backup-rename dance — those added moving parts that hung
// (`hdiutil detach`) and raced. Any failure before the hand-off surfaces as
// `.failure` so the caller can fall back to opening the releases page.
//
// SECURITY INVARIANT: the install target is ALWAYS the running bundle
// (`Bundle.main.bundlePath`), never a hardcoded /Applications. A test copy run
// from build/dist therefore updates *itself*, not a real install. The dmg URL
// is still gated through `isTrustedSource` (https on a GitHub release origin).

import Foundation
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
        /// `downloadAndInstall` (part 2), which downloads it to a temp file and
        /// hands it to the installer script.
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

    /// Errors raised by the download/install path. All of them mean
    /// "auto-update failed" → the caller falls back to the releases page.
    enum InstallError: LocalizedError {
        case noDMG                         // the release had no .dmg asset
        case untrustedSource               // dmg URL not https on an allowed host
        case downloadFailed                // dmg GET failed / non-2xx / too small
        case scriptWriteFailed             // couldn't write the install script
        case launchFailed                  // couldn't spawn the detached installer

        var errorDescription: String? {
            switch self {
            case .noDMG:             return "В релизе нет .dmg для автоматической установки."
            case .untrustedSource:   return "Источник обновления не прошёл проверку безопасности."
            case .downloadFailed:    return "Не удалось скачать обновление."
            case .scriptWriteFailed: return "Не удалось подготовить установщик."
            case .launchFailed:      return "Не удалось запустить установщик."
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

    /// Download `info.dmgURL` to a temp file, sanity-check its size, then kick off
    /// the detached installer and quit the app. On any failure BEFORE the hand-off,
    /// `completion(.failure)` is called and the app stays running.
    ///
    /// Deliberately minimal — modeled on the sibling "Claude Codex Limits" updater:
    ///   1. trust-gate the dmg URL (https on a GitHub origin),
    ///   2. download it to `NSTemporaryDirectory()/fb2-update.dmg`,
    ///   3. cheap sanity check: a real dmg is far bigger than 100 KB (a 404/error
    ///      body or truncated transfer is not), so reject anything smaller,
    ///   4. write a tiny bash installer to `NSTemporaryDirectory()/fb2-update.sh`,
    ///   5. spawn it via `/bin/bash <script>` and ask the app to quit.
    ///
    /// `completion` may run on a background thread — the caller hops to main for UI.
    /// On SUCCESS the installer has been launched and `NSApp.terminate` requested;
    /// `completion` is NOT called in that case (the process is on its way out). The
    /// script's leading `sleep 1.5` covers the brief window until this process exits.
    static func downloadAndInstall(
        _ info: UpdateInfo,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let dmgURL = info.dmgURL else {
            completion(.failure(InstallError.noDMG))
            return
        }
        // Refuse anything that isn't https on a GitHub release origin (downgrade /
        // host-swap defense). Cheap and breaks nothing legitimate.
        guard isTrustedSource(dmgURL) else {
            completion(.failure(InstallError.untrustedSource))
            return
        }

        var request = URLRequest(url: dmgURL)
        request.setValue("fb2-to-epub", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120

        // downloadTask streams to disk so a large dmg is never held in memory.
        let task = URLSession.shared.downloadTask(with: request) { tmpURL, response, error in
            if error != nil {
                completion(.failure(InstallError.downloadFailed))
                return
            }
            guard
                let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode),
                let tmpURL = tmpURL
            else {
                completion(.failure(InstallError.downloadFailed))
                return
            }

            let fm = FileManager.default
            let dmgPath = NSTemporaryDirectory() + "fb2-update.dmg"
            let dmgDest = URL(fileURLWithPath: dmgPath)
            do {
                if fm.fileExists(atPath: dmgPath) { try fm.removeItem(at: dmgDest) }
                try fm.moveItem(at: tmpURL, to: dmgDest)
            } catch {
                completion(.failure(InstallError.downloadFailed))
                return
            }

            // Cheap sanity check (same bar as the reference app): a genuine dmg is
            // far larger than 100 KB — a tiny payload means a 404/error body or a
            // truncated transfer slipped through as a 2xx.
            let size = (try? fm.attributesOfItem(atPath: dmgPath))?[.size] as? Int ?? 0
            guard size > 100_000 else {
                try? fm.removeItem(at: dmgDest)
                completion(.failure(InstallError.downloadFailed))
                return
            }

            // Verified enough → write the script, launch detached, quit.
            do {
                try launchInstaller(dmgPath: dmgPath)
                // Hand-off done; the script owns the rest. No completion on success.
            } catch {
                completion(.failure(error))
            }
        }
        task.resume()
    }

    // MARK: Install hand-off

    /// Write the tiny detached installer to `NSTemporaryDirectory()/fb2-update.sh`,
    /// spawn it via `/bin/bash <script>`, then ask the app to quit.
    ///
    /// The installer is intentionally minimal (mirrors the sibling app): it sleeps
    /// briefly to let this process exit, mounts the dmg, copies the new bundle over
    /// the RUNNING one (`Bundle.main.bundlePath` — never a hardcoded /Applications),
    /// strips quarantine, detaches, and relaunches. Paths are interpolated inside
    /// double quotes, so spaces in the bundle/temp path are handled by the shell.
    private static func launchInstaller(dmgPath: String) throws {
        let appPath = Bundle.main.bundlePath
        let scriptPath = NSTemporaryDirectory() + "fb2-update.sh"
        let script = """
        #!/bin/bash
        sleep 1.5
        DMG="\(dmgPath)"
        APP="\(appPath)"
        MP=$(/usr/bin/hdiutil attach "$DMG" -nobrowse -noverify 2>/dev/null | grep '/Volumes/' | sed -n 's/.*\\(\\/Volumes\\/.*\\)/\\1/p' | tail -1)
        SRC="$MP/fb2-to-epub.app"
        if [ -n "$MP" ] && [ -d "$SRC" ]; then
          /bin/rm -rf "$APP"
          /bin/cp -R "$SRC" "$APP"
          /usr/bin/xattr -dr com.apple.quarantine "$APP" 2>/dev/null
          /usr/bin/hdiutil detach "$MP" >/dev/null 2>&1
          /usr/bin/open "$APP"
        fi
        /bin/rm -f "$DMG" "\(scriptPath)"
        """

        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        } catch {
            throw InstallError.scriptWriteFailed
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath]
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
}
