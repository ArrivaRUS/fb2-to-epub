// EngineClient — thin Swift bridge between the SwiftUI app and the existing
// shell engine (LaunchAgent + installer.sh + Calibre). M1.
//
// Design rules (from arch/plans-ui.md, "Инварианты" + "Контракты данных"):
//   - The engine logic is NOT changed here. We only *call* installer.sh and
//     read agent state via launchctl / plutil.
//   - runner.sh / watcher.sh are never invoked from Swift.
//   - The app is unsandboxed, no external Swift deps: Foundation only.
//
// Everything here shells out via Process. Arguments are passed as a real argv
// array (never spliced into a shell string), so paths with spaces / unicode are
// safe — same contract the installer relies on (plutil, not sed).

import Foundation

// MARK: - Public model

/// Resolved state of the LaunchAgent, as the UI needs to render it.
///
/// IMPORTANT (Codex's nuance, confirmed by `launchctl print` on a real agent):
/// the agent is *event-driven*. In the normal idle case `launchctl print`
/// reports `state = not running` — that is healthy, not an error. So "active"
/// is defined as: `launchctl print` returned 0  AND  the plist exists  AND  the
/// label is not disabled. A running pid is NOT required.
struct AgentStatus {
    /// `launchctl print gui/$UID/<label>` returned rc == 0 (agent is bootstrapped).
    var isLoaded: Bool
    /// Label is disabled in the user domain (`launchctl print-disabled` => disabled).
    var isDisabled: Bool
    /// `state = running` was seen in `launchctl print` (informational only).
    var isRunning: Bool
    /// Whether the LaunchAgent plist file exists on disk.
    var plistExists: Bool

    /// The UI's single source of truth: is the agent effectively active?
    /// active = bootstrapped (rc 0) AND plist present AND not disabled.
    /// Running pid is intentionally NOT part of this — the agent is event-driven.
    var isActive: Bool { isLoaded && plistExists && !isDisabled }
}

/// Result of the first-run / migration decision.
enum FirstRunOutcome: Equatable {
    /// No plist existed → installer was run on the given default folder.
    case installedDefault(watchDir: String)
    /// A plist already existed → we kept the user's existing WATCH_DIR untouched.
    case migratedExisting(watchDir: String)
    /// Движка НЕТ — installer даже не звали. UI предлагает поставить Calibre.
    /// (CAL-1: раньше это и следующий случай маскировались одним blockedNoCalibre.)
    case needsEngine
    /// Движок ЕСТЬ, но installer вернул ненулевой код — агент не поднялся.
    /// Это НЕ повод предлагать установку движка: чинить надо запуск агента.
    case agentSetupFailed
}

/// One-shot snapshot the UI reads to prove the bridge works (M1 placeholder
/// screen; the real Status screen lands at M2).
struct EngineSnapshot {
    var watchDir: String?
    var agent: AgentStatus
    var calibreInstalled: Bool
}

// MARK: - EngineClient

/// All paths are derived from `home` so the whole client can be pointed at a
/// throwaway HOME (and a throwaway label) for isolated tests — without ever
/// touching the user's real agent or watch folder.
struct EngineClient {

    // --- configuration -----------------------------------------------------

    /// LaunchAgent label. Default is the production label; tests override it
    /// with a throwaway label so they never collide with the real agent.
    let label: String

    /// Home directory root. Default is the real HOME; tests point it at a
    /// `mktemp -d` so the installer writes into a sandbox.
    let home: String

    /// Absolute path to the bundled installer.sh (in the .app Resources, or a
    /// checkout path for tests).
    let installerPath: String

    /// ЯВНЫЙ оверрайд пути к `ebook-convert`. По умолчанию nil → путь целиком
    /// определяет `CalibreLocator` (контракт детекта, инвариант 5).
    ///
    /// Оверрайд оставлен для тестов, которые подсовывают сюда `/bin/echo`: для
    /// него проверяется ТОЛЬКО сам файл (без meta/polish рядом) — прежняя
    /// M1-семантика «есть исполняемый файл = движок есть». Продакшен ходит
    /// через локатор, где валидность = все три CLI.
    let ebookConvertOverride: String?

    init(
        label: String = "com.arrivarus.fb2toepub.agent",
        home: String = EngineHome.resolve(),
        installerPath: String,
        ebookConvertPath: String? = nil
    ) {
        self.label = label
        self.home = home
        self.installerPath = installerPath
        self.ebookConvertOverride = ebookConvertPath
    }

    // --- derived paths -----------------------------------------------------

    /// `~/Library/LaunchAgents/<label>.plist`
    var plistPath: String {
        "\(home)/Library/LaunchAgents/\(label).plist"
    }

    /// `gui/<uid>/<label>` — the launchd service target.
    private var serviceTarget: String { "gui/\(getuid())/\(label)" }
    private var domainTarget: String { "gui/\(getuid())" }

    // MARK: - Process helper

    /// Result of running a child process.
    struct RunResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Run an executable with an explicit argv array. No shell, no string
    /// splicing. `env` is merged onto the current environment when provided
    /// (used to inject a throwaway HOME for the installer in tests).
    @discardableResult
    func run(_ launchPath: String, _ args: [String], env: [String: String]? = nil) -> RunResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        if let env = env {
            var merged = ProcessInfo.processInfo.environment
            for (k, v) in env { merged[k] = v }
            proc.environment = merged
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            return RunResult(status: -1, stdout: "", stderr: "spawn failed: \(error)")
        }

        // Read both pipes fully BEFORE waitUntilExit to avoid a deadlock if the
        // child fills a pipe buffer (launchctl print can be large).
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        return RunResult(
            status: proc.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    // MARK: - Calibre probe (контракт детекта — CalibreLocator)

    /// Текущая локация движка по контракту (CAL-1). nil = движка нет.
    /// Все пути считаются от `home`, поэтому изолированный тест остаётся изолированным.
    func calibreLocation() -> CalibreLocation? {
        CalibreLocator.resolve(home: home)
    }

    /// Абсолютный путь к `ebook-convert`: явный оверрайд → локатор → "" (движка нет).
    /// Пустая строка недостижима для вызывающих: все они идут через
    /// `calibreInstalled()`, который в этом случае уже вернул false.
    var ebookConvertPath: String {
        ebookConvertOverride ?? calibreLocation()?.ebookConvert ?? ""
    }

    /// Движок есть?
    ///   • с явным оверрайдом — исполняем ли ИМЕННО он (прежняя M1-семантика);
    ///   • без оверрайда — нашёл ли локатор валидную локацию (все три CLI).
    func calibreInstalled() -> Bool {
        if let override = ebookConvertOverride {
            return CalibreLocator.isExecutableRegularFile(override)
        }
        return calibreLocation() != nil
    }

    // MARK: - Raw history (гибрид подачи D37)

    /// Есть ли у пользователя история конвертаций по СЫРОМУ снапшоту `state.json`
    /// (`converted_total > 0 || recent непуст || last_conversion != nil`).
    ///
    /// Определяет подачу онбординга без движка: история ЕСТЬ → баннер A (не прячем
    /// уже сконвертированные книги), НЕТ → блокер B (показывать нечего, ведём в одно
    /// действие). Считается по СЫРОМУ `StateStore.load()`, а НЕ по отфильтрованному
    /// `loadState()`: иначе «Сбросить статистику» / «Очистить» превратили бы баннер
    /// в блокер (D37, решение суда архитекторов). Тот же сигнал питает
    /// `shouldShowSetup` — единый helper, чтобы две ветки не разъехались.
    func hasRawHistory() -> Bool {
        let raw = StateStore(home: home).load()
        return raw.totals.convertedTotal > 0 || !raw.recent.isEmpty || raw.lastConversion != nil
    }

    // MARK: - Watch dir (read from installed plist)

    func plistExists() -> Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    /// Read the installed WATCH_DIR straight from the plist's EnvironmentVariables
    /// via `plutil -extract` (the same typed value the installer wrote). Returns
    /// nil when the plist is absent or the key is missing.
    func readWatchDir() -> String? {
        guard plistExists() else { return nil }
        let r = run("/usr/bin/plutil",
                    ["-extract", "EnvironmentVariables.WATCH_DIR", "raw", "-o", "-", plistPath])
        guard r.status == 0 else { return nil }
        let value = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: - launchctl: status

    /// `launchctl print <target>` + `launchctl print-disabled <domain>` parsed
    /// into an AgentStatus. See AgentStatus doc for why running is not required.
    func agentStatus() -> AgentStatus {
        let printRes = run("/bin/launchctl", ["print", serviceTarget])
        let isLoaded = printRes.status == 0

        // `state = running` is informational only (event-driven agent idles as
        // "not running"). Match the exact token launchctl prints.
        let isRunning = Self.parseIsRunning(fromPrint: printRes.stdout)

        let disabledRes = run("/bin/launchctl", ["print-disabled", domainTarget])
        let isDisabled = Self.parseIsDisabled(fromPrintDisabled: disabledRes.stdout, label: label)

        return AgentStatus(
            isLoaded: isLoaded,
            isDisabled: isDisabled,
            isRunning: isRunning,
            plistExists: plistExists()
        )
    }

    /// Parse `state = running` from `launchctl print` output.
    /// launchctl prints e.g. `\tstate = running` or `\tstate = not running`.
    static func parseIsRunning(fromPrint out: String) -> Bool {
        for rawLine in out.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("state") else { continue }
            // Only the top-level service `state = ...` line (there are nested
            // `state = active` lines for endpoints — those are not the pid state).
            // The service line has the form "state = running" / "state = not running".
            if let eq = line.firstIndex(of: "=") {
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if value == "running" { return true }
                if value == "not running" { return false }
            }
        }
        return false
    }

    /// Parse `"<label>" => disabled` / `=> enabled` from `launchctl print-disabled`.
    /// Default-absent label is treated as NOT disabled (launchctl omits labels
    /// it has no explicit disable record for).
    static func parseIsDisabled(fromPrintDisabled out: String, label: String) -> Bool {
        let needle = "\"\(label)\""
        for rawLine in out.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.contains(needle) else { continue }
            // Form: "com.x.y" => disabled  |  "com.x.y" => enabled
            if line.contains("=> disabled") { return true }
            if line.contains("=> enabled") { return false }
        }
        return false
    }

    // MARK: - launchctl: lifecycle wrappers (used by install/repair flows)

    @discardableResult
    func bootout() -> RunResult {
        run("/bin/launchctl", ["bootout", serviceTarget])
    }

    @discardableResult
    func bootstrap() -> RunResult {
        run("/bin/launchctl", ["bootstrap", domainTarget, plistPath])
    }

    @discardableResult
    func kickstart() -> RunResult {
        run("/bin/launchctl", ["kickstart", "-k", serviceTarget])
    }

    // MARK: - installer.sh

    /// Run installer.sh with WATCH_DIR as a single argv element (no shell glue).
    /// installer.sh itself does the heavy lifting: Calibre detect, plist via
    /// plutil, bootout→bootstrap→enable→kickstart.
    ///
    /// `extraEnv` lets tests inject HOME (so the plist lands in a throwaway tree)
    /// and FB2_SRC_DIR (so the installer finds the engine scripts from a checkout).
    @discardableResult
    func runInstaller(watchDir: String, extraEnv: [String: String]? = nil) -> RunResult {
        run("/bin/bash", [installerPath, watchDir], env: extraEnv)
    }

    // MARK: - First-run / migration logic

    /// Decide what to do on launch:
    ///   - plist exists  → READ existing WATCH_DIR, do NOT overwrite (migration
    ///                      from an older applet/version).
    ///   - no plist      → install onto `~/Desktop/fb2-to-epub` (the default).
    ///   - Calibre absent and we'd need to install → report blocked, let the UI
    ///                      surface guidance (the install button lands at M2/M3).
    ///
    /// `defaultWatchDir` defaults to `<home>/Desktop/fb2-to-epub`.
    /// `extraEnv` is forwarded to the installer (tests inject HOME/FB2_SRC_DIR).
    @discardableResult
    func firstRunSetupIfNeeded(defaultWatchDir: String? = nil,
                               extraEnv: [String: String]? = nil) -> FirstRunOutcome {
        // Migration branch: never clobber an existing user folder.
        if plistExists() {
            let existing = readWatchDir() ?? "\(home)/Desktop/fb2-to-epub"
            return .migratedExisting(watchDir: existing)
        }

        // Fresh install branch — needs Calibre (installer would exit 1 otherwise).
        guard calibreInstalled() else {
            return .needsEngine
        }

        let target = defaultWatchDir ?? "\(home)/Desktop/fb2-to-epub"
        let res = runInstaller(watchDir: target, extraEnv: extraEnv)
        if res.status == 0 {
            // Read back what the installer actually wrote (it normalizes the path).
            return .installedDefault(watchDir: readWatchDir() ?? target)
        }
        // Движок на месте, а installer упал — честно называем это провалом
        // ЗАПУСКА АГЕНТА (UI не должен предлагать «поставить Calibre»).
        return .agentSetupFailed
    }

    // MARK: - Snapshot for UI

    /// One read pass for the placeholder screen: watch dir + agent state + Calibre.
    func snapshot() -> EngineSnapshot {
        EngineSnapshot(
            watchDir: readWatchDir(),
            agent: agentStatus(),
            calibreInstalled: calibreInstalled()
        )
    }
}
