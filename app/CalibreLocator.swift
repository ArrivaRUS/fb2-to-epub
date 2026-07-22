// CalibreLocator — ЕДИНЫЙ контракт детекта движка (CAL-1).
//
// Инвариант 5 (plans.md): знание «где Calibre» живёт в ОДНОМ месте, а не
// россыпью хардкодов. Порядок кандидатов:
//
//   1. <home>/Library/Application Support/fb2-to-epub/calibre.app   (app-owned)
//   2. /Applications/calibre.app                                     (system)
//   3. <home>/Applications/calibre.app                               (user)
//
// Локация ВАЛИДНА только если исполняемы ВСЕ ТРИ CLI (ebook-convert,
// ebook-meta, ebook-polish): частичный/битый Calibre — это «движка нет», а не
// «движок есть, но потом упадёт на обложках».
//
// Тот же контракт продублирован на bash в packaging/installer.sh (§1); их
// синхронность держит tests/run-calibre-locator-parity.sh. Новые хардкоды
// «/Applications/calibre.app» вне этого файла / детекта installer'а / фолбэков
// watcher'а запрещены — tests/run-calibre-hardcode-grep.sh.
//
// PATH и homebrew-bin НЕ сканируем сознательно: cask кладёт .app в
// /Applications (кандидат 2), а обёртки в /opt/homebrew/bin — симлинки туда же.
//
// Файл Foundation-only: его компилируют и приложение, и headless-тесты.

import Foundation

// MARK: - Найденная локация

/// Валидная (все 3 CLI на месте) установка Calibre.
struct CalibreLocation: Equatable {

    /// Откуда именно взят движок — нужно UI («ставили мы» vs «стоит системный»)
    /// и тестам (проверить, что порядок кандидатов соблюдён).
    enum Kind: String, Equatable {
        /// `<FB2_CALIBRE_TEST_ROOT>/calibre.app` — ТОЛЬКО под тест-защёлкой.
        case testRoot
        /// `<home>/Library/Application Support/fb2-to-epub/calibre.app` — наша установка.
        case appOwned
        /// `/Applications/calibre.app` — системная (в т.ч. brew --cask).
        case system
        /// `<home>/Applications/calibre.app` — установка «для себя».
        case userApplications
    }

    /// Три CLI, без которых установка считается неполной.
    static let requiredCLIs = ["ebook-convert", "ebook-meta", "ebook-polish"]

    /// `<...>/calibre.app/Contents/MacOS` — то, что уезжает в plist как CALIBRE_MACOS_DIR.
    let macosDir: String
    let kind: Kind

    var ebookConvert: String { "\(macosDir)/ebook-convert" }
    var ebookMeta: String { "\(macosDir)/ebook-meta" }
    var ebookPolish: String { "\(macosDir)/ebook-polish" }
}

// MARK: - Тест-защёлка (урок 015)

/// Защёлка для тест-оверрайдов. Урок 015: verify-оверрайд однажды дотянулся до
/// боевого инсталлера и переписал реальный plist агента человека. Поэтому:
///
///   • read-only оверрайды (подмена кандидатов детекта) требуют
///     `FB2_CALIBRE_TEST_MODE=1` + существующий `FB2_CALIBRE_TEST_ROOT`;
///   • MUTATING оверрайды (URL скачивания, метка агента, пропуск codesign)
///     требуют ДОПОЛНИТЕЛЬНО, чтобы install-root лежал ВНУТРИ канонизированного
///     TEST_ROOT — `allowsMutation(installRoot:)`.
///
/// Без защёлки переменные молча игнорируются: попадание такого env на боевую
/// машину не должно ничего менять.
enum CalibreTestLatch {

    static let testModeKey = "FB2_CALIBRE_TEST_MODE"
    static let testRootKey = "FB2_CALIBRE_TEST_ROOT"
    static let disableSystemKey = "FB2_CALIBRE_DISABLE_SYSTEM"

    /// Канонизированный TEST_ROOT, если защёлка взведена; иначе nil.
    static func testRoot(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard env[testModeKey] == "1" else { return nil }
        guard let raw = env[testRootKey], !raw.isEmpty else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: raw, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        let root = canonical(raw)
        // Ужесточение защёлки (D-ревью): слишком широкий TEST_ROOT сделал бы «внутри TEST_ROOT»
        // боевые пути → мутирующие оверрайды навелись бы на прод. Такой TEST_ROOT — не защёлка:
        //   • `/` — внутри него вообще всё;
        //   • TEST_ROOT, СОДЕРЖАЩИЙ настоящий домашний каталог пользователя (getpwuid, НЕ $HOME:
        //     тесты гоняются с throwaway-$HOME внутри TEST_ROOT — сверять надо с реальным home).
        if root == "/" { return nil }
        if let home = passwdHome(), isInside(path: home, root: root) { return nil }
        return root
    }

    /// Домашний каталог ПОЛЬЗОВАТЕЛЯ из базы паролей (`getpwuid(getuid())`), канонизированный.
    /// Именно passwd-home, а НЕ `$HOME`: изолированные тесты подменяют `$HOME` throwaway-путём
    /// внутри TEST_ROOT, и защёлка не должна из-за этого ломаться — сверяемся с настоящим домом.
    private static func passwdHome() -> String? {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return nil }
        return canonical(String(cString: dir))
    }

    /// Можно ли применять MUTATING оверрайд для установки в `installRoot`.
    /// Требует и взведённой защёлки, и install-root внутри TEST_ROOT.
    static func allowsMutation(installRoot: String,
                               env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let root = testRoot(env: env) else { return false }
        return isInside(path: canonical(installRoot), root: root)
    }

    /// Канонизация ПО СЕМАНТИКЕ `realpath(3)` — той же, что даёт bash `cd … && pwd -P`
    /// в installer.sh. Это важно: NSString.resolvingSymlinksInPath делает ОБРАТНОЕ
    /// (срезает ведущий /private), и две реализации контракта расходились бы
    /// строками для одного и того же каталога.
    ///
    /// Путь может ещё не существовать (install-root до первой установки), поэтому
    /// realpath применяется к самому длинному СУЩЕСТВУЮЩЕМУ префиксу, а хвост
    /// дописывается как есть.
    static func canonical(_ path: String) -> String {
        var expanded = (path as NSString).expandingTildeInPath
        while expanded.count > 1, expanded.hasSuffix("/") { expanded.removeLast() }
        guard expanded.hasPrefix("/") else { return expanded }

        var missing: [String] = []
        var probe = expanded
        while true {
            if let raw = realpath(probe, nil) {
                let resolved = String(cString: raw)
                free(raw)
                var out = resolved as NSString
                for comp in missing.reversed() {
                    out = out.appendingPathComponent(comp) as NSString
                }
                return out as String
            }
            if probe == "/" { break }
            let parent = (probe as NSString).deletingLastPathComponent
            if parent == probe || parent.isEmpty { break }
            missing.append((probe as NSString).lastPathComponent)
            probe = parent
        }
        return expanded
    }

    /// `path` — это `root` или что-то под ним (сравнение по границе сегмента,
    /// чтобы `/tmp/root-evil` не считался лежащим внутри `/tmp/root`).
    static func isInside(path: String, root: String) -> Bool {
        if path == root { return true }
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

// MARK: - Резолвер домашней директории (П1)

/// ЕДИНЫЙ источник `home` для всей engine-части приложения (локатор, установщик,
/// EngineClient, пути state/covers/plist в main.swift).
///
/// Появился после того, как допущение plans.md «NSHomeDirectory() уважает $HOME»
/// было ОПРОВЕРГНУТО живой пробой (Darwin 25.5): у НАПРЯМУЮ запущенного бинаря
/// `NSHomeDirectory()` возвращает РЕАЛЬНЫЙ дом пользователя, игнорируя `$HOME` из
/// окружения (`ProcessInfo.environment["HOME"]` при этом — throwaway). Из-за этого
/// throwaway-HOME-харнесс НЕ изолировал приложение: install-root считался от боевого
/// дома, и срабатывал `halfCockedTestLatch` (громкий отказ — предохранитель отработал).
///
/// Контракт (та же граница изоляции, что у `CalibreTestLatch`):
///   • `FB2_CALIBRE_TEST_MODE=1` И env `HOME` задан И
///     `canonical(HOME + "/Library/Application Support/fb2-to-epub")` лежит ВНУТРИ
///     канонизированного `FB2_CALIBRE_TEST_ROOT` → берём env `HOME`;
///   • иначе → `NSHomeDirectory()` (прод-путь, поведение байт-в-байт прежнее).
/// В проде (нет `FB2_CALIBRE_TEST_MODE`) ветка недостижима.
enum EngineHome {

    static func resolve(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        guard env[CalibreTestLatch.testModeKey] == "1",
              let envHome = env["HOME"], !envHome.isEmpty,
              let root = CalibreTestLatch.testRoot(env: env),
              CalibreTestLatch.isInside(
                  path: CalibreTestLatch.canonical(CalibreLocator.appOwnedRoot(home: envHome)),
                  root: root)
        else {
            return NSHomeDirectory()
        }
        return envHome
    }
}

// MARK: - Локатор

enum CalibreLocator {

    /// Кандидат детекта: путь к .app-бандлу + откуда он взялся.
    struct Candidate: Equatable {
        let appPath: String
        let kind: CalibreLocation.Kind

        /// `<appPath>/Contents/MacOS`
        var macosDir: String { "\(appPath)/Contents/MacOS" }
    }

    /// Корень наших app-owned данных: сюда CalibreInstaller (CAL-3) кладёт calibre.app.
    static func appOwnedRoot(home: String) -> String {
        "\(home)/Library/Application Support/fb2-to-epub"
    }

    /// Список кандидатов В ПОРЯДКЕ КОНТРАКТА.
    ///
    /// Под защёлкой перед app-owned ВСТАВЛЯЕТСЯ (не заменяет!) `<TEST_ROOT>/calibre.app`,
    /// а `FB2_CALIBRE_DISABLE_SYSTEM=1` убирает кандидатов 2–3 (/Applications и
    /// ~/Applications) — так тест видит «движка нет» на машине, где Calibre стоит.
    /// Без защёлки оба env игнорируются.
    static func candidates(home: String,
                           env: [String: String] = ProcessInfo.processInfo.environment) -> [Candidate] {
        var out: [Candidate] = []

        let latchRoot = CalibreTestLatch.testRoot(env: env)
        if let root = latchRoot {
            out.append(Candidate(appPath: "\(root)/calibre.app", kind: .testRoot))
        }

        out.append(Candidate(appPath: "\(appOwnedRoot(home: home))/calibre.app", kind: .appOwned))

        let systemDisabled = (latchRoot != nil) && env[CalibreTestLatch.disableSystemKey] == "1"
        if !systemDisabled {
            out.append(Candidate(appPath: "/Applications/calibre.app", kind: .system))
            out.append(Candidate(appPath: "\(home)/Applications/calibre.app", kind: .userApplications))
        }

        return out
    }

    /// Первый ВАЛИДНЫЙ кандидат из списка (или nil).
    static func resolve(candidates list: [Candidate]) -> CalibreLocation? {
        for c in list where isValid(macosDir: c.macosDir) {
            return CalibreLocation(macosDir: c.macosDir, kind: c.kind)
        }
        return nil
    }

    /// Контракт целиком: кандидаты по `home`/env → первый валидный.
    static func resolve(home: String = EngineHome.resolve(),
                        env: [String: String] = ProcessInfo.processInfo.environment) -> CalibreLocation? {
        resolve(candidates: candidates(home: home, env: env))
    }

    /// Валидность = все три CLI — исполняемые обычные файлы.
    static func isValid(macosDir: String) -> Bool {
        for cli in CalibreLocation.requiredCLIs where !isExecutableRegularFile("\(macosDir)/\(cli)") {
            return false
        }
        return true
    }

    /// Обычный файл (не каталог) с битом +x. Каталог с +x — не CLI.
    static func isExecutableRegularFile(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }
}
