// CalibreInstaller — headless-конвейер установки движка Calibre (CAL-3).
//
// ЧТО ДЕЛАЕТ (машина состояний flow.md §3):
//   precheck (диск ≥1,5 ГБ — D41; OS-гейт ≥14 — D42)
//     → download (прогресс, отмена, trust-gate хостов)
//     → SHA-512 fail-closed
//     → mount (hdiutil -plist)
//     → LSMinimumSystemVersion-чек
//     → ditto в staging → codesign --verify + exec --version
//     → атомарный своп → зачистка.
//
// КРАСНЫЕ ЛИНИИ (инварианты plans.md):
//   • инв.3: пишем ТОЛЬКО в app-owned `App Support/fb2-to-epub/{downloads,calibre.app*}`.
//     Чужой системный бандл в /Applications не трогаем (его литерала тут нет — hardcode-grep).
//   • инв.4 (GPL): бинарники Calibre не в git/DMG — только рантайм-скачивание с офиц. URL.
//   • инв.6 (урок 015): mutating-оверрайды (URL DMG/SHA, пропуск codesign) действуют ТОЛЬКО
//     под защёлкой CalibreTestLatch (TEST_MODE=1 И install-root внутри TEST_ROOT). Иначе — молча
//     игнорируются: прод-пути.
//   • инв.10: https-only, allow-хосты calibre-ebook.com · download.calibre-ebook.com · github.com ·
//     *.githubusercontent.com. Quarantine НЕ снимаем (честный фэйл → manual).
//   • инв.8 (урок 006): без докачки/resume, без GPG, без transaction-journal, без легаси-пиннинга.
//
// АРХИТЕКТУРА ФАЙЛА:
//   • `CalibreInstaller` — чистый headless-движок с инъектируемым `Config` (home/env/пороги/ОС/
//     URLSession). Никакого SwiftUI/AppKit, никаких предположений о main-потоке — полностью
//     тестируется fixture-DMG без сети и без 330 МБ (см. tests/run-calibre-install-tests.sh).
//   • `InstallStore: ObservableObject` — тонкая UI-обёртка (владелец — AppDelegate, сшивка в CAL-4):
//     @Published-фаза, re-entry guard, взаимоисключение с авто-апдейтом приложения.
//
// Foundation + Combine only → компилируется и в приложение, и в headless-тест рядом с CalibreLocator.

import Foundation
import Combine
import CryptoKit

// MARK: - Фаза установки (task 3.1)

/// Состояния конвейера. Терминальные: success · error · manual · (idle после отмены).
enum InstallPhase: Equatable {
    case idle
    case precheck
    case downloading(got: Int64, total: Int64)
    case installing
    case verifying
    case activating
    case success
    case error(Reason)
    /// Движок установлен, но launchd-агент не поднялся — НЕ провал установки (CAL-4 действие
    /// «Повторить запуск агента»). Движок сам конвейер выставить не может; фазу заводит store.
    case agentActivationFailed
    /// Автоустановка недоступна (macOS < 14 — D42) → только ручная подача.
    case manual

    enum Reason: String, Equatable {
        case network   // нет сети / non-2xx / обрыв / подозрительно маленький файл
        case space     // на томе App Support < порога (D41)
        case install   // SHA не сошёлся · нет calibre.app · verify упал · mount/ditto/swap упали
    }

    /// Терминальная фаза — конвейер (или активация) больше не движется: success ·
    /// error · manual · agentActivationFailed · idle (после отмены). CAL-4 D40:
    /// `.terminateLater`-reply даётся именно на терминальной фазе (безопасная точка).
    var isTerminal: Bool {
        switch self {
        case .idle, .success, .error, .manual, .agentActivationFailed: return true
        case .precheck, .downloading, .installing, .verifying, .activating: return false
        }
    }

    /// Идёт ли мутирующая работа прямо сейчас (для D40-политики terminate и
    /// `applicationShouldTerminateAfterLastWindowClosed`). Скачивание/установка/
    /// проверка/активация — «в полёте»; терминальные — нет.
    var isInFlight: Bool { !isTerminal }
}

// MARK: - Движок

final class CalibreInstaller {

    // MARK: Конфиг (всё инъектируемо — тестам маленькие пороги / фикстурные URL)

    struct Config {
        /// Домашняя папка (в тестах — throwaway HOME под защёлкой). Прод: NSHomeDirectory().
        var home: String
        /// Срез окружения — читают и защёлка, и оверрайды. Прод: ProcessInfo; тестам — явный словарь.
        var env: [String: String]
        /// Пре-чек диска (D41: реальный пик ~1,1 ГБ, порог 1,5 ГБ). Тестам — крошечный/огромный.
        var diskThresholdBytes: Int64 = 1_500_000_000
        /// OS-гейт автоустановки (D42: Calibre 9.x требует macOS 14+).
        var minAutoInstallMajorOS: Int = 14
        /// Текущая ОС (для OS-гейта и сверки LSMinimumSystemVersion). Прод: ProcessInfo.
        var currentOS: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
        /// Санити-порог размера DMG: настоящий образ ≫ этого, 404/обрыв — меньше. Тестам — маленький.
        var minDownloadBytes: Int64 = 50_000_000
        /// Таймаут сетевых запросов.
        var networkTimeout: TimeInterval = 120
        /// Сессия для скачивания/GET (тестам можно подменить). По умолчанию — эфемерная.
        var session: URLSession = {
            let c = URLSessionConfiguration.ephemeral
            c.requestCachePolicy = .reloadIgnoringLocalCacheData
            return URLSession(configuration: c)
        }()
    }

    // MARK: Константы (зафиксированы живой пробой 3.0, 2026-07-21)

    /// «Последняя версия» — 302 → github releases текущей версии (universal DMG, ~328,5 МБ).
    static let productionDMGURL = URL(string: "https://calibre-ebook.com/dist/osx")!
    /// SHA-512 сайдкар: `<base>calibre-<ver>.dmg.sha512` (128 hex, без имени файла и \n).
    static let signatureBase = "https://calibre-ebook.com/signatures/"
    /// Фолбэк версии, если не удалось вытащить из имени файла/URL (task 3.6). Метаданные, не бинарь.
    static let versionFallbackAPI = URL(string: "https://api.github.com/repos/kovidgoyal/calibre/releases/latest")!

    /// Allow-хосты для СКАЧИВАНИЯ артефактов (инв.10). Точное совпадение + суффикс.
    static let allowedHosts: Set<String> = ["calibre-ebook.com", "download.calibre-ebook.com", "github.com"]
    static let allowedHostSuffix = ".githubusercontent.com"
    /// Отдельный allow ТОЛЬКО для version-фолбэка (метаданные, не бинарь) — см. task 3.6 / риск в отчёте.
    static let versionMetadataHosts: Set<String> = ["api.github.com"]

    // Ключи mutating-оверрайдов (инв.6 — действуют только под защёлкой).
    static let dmgURLKey = "FB2_CALIBRE_DMG_URL"
    static let sha512URLKey = "FB2_CALIBRE_SHA512_URL"
    static let skipCodesignKey = "FB2_CALIBRE_SKIP_CODESIGN"

    // MARK: Состояние

    let config: Config
    private let fm = FileManager.default
    private let lock = NSLock()
    private var currentTask: URLSessionDownloadTask?
    private var cancelRequested = false
    /// Base-disk смонтированного образа (для detach в cleanup). nil = ничего не смонтировано.
    private var mountedDev: String?

    /// Тест-seam (S1) ТОЛЬКО для второго rename свопа (staging → calibre.app): по умолчанию
    /// nil → настоящий `FileManager.moveItem`. Юнит подменяет бросающим замыканием, чтобы
    /// смоделировать провал promote и проверить откат `.old → calibre.app`. В проде nil.
    var swapPromoteHook: ((_ from: String, _ to: String) throws -> Void)?

    init(config: Config) { self.config = config }

    // MARK: Пути (все — под app-owned корнем; чужих мест нет)

    var appOwnedRoot: String { CalibreLocator.appOwnedRoot(home: config.home) }
    var downloadsDir: String { "\(appOwnedRoot)/downloads" }
    var dmgPath: String { "\(downloadsDir)/calibre.dmg" }
    var mountPoint: String { "\(downloadsDir)/mnt" }
    var installedApp: String { "\(appOwnedRoot)/calibre.app" }
    var stagingApp: String { "\(appOwnedRoot)/calibre.app.installing" }
    var oldApp: String { "\(appOwnedRoot)/calibre.app.old" }

    /// Можно ли применять mutating-оверрайды: защёлка взведена И install-root внутри TEST_ROOT.
    var mutationAllowed: Bool {
        CalibreTestLatch.allowsMutation(installRoot: appOwnedRoot, env: config.env)
    }

    /// «Полузведённая» тест-защёлка (дополнение D-ревью 2026-07-21): `TEST_MODE=1` И задан
    /// оверрайд `FB2_CALIBRE_DMG_URL`, НО мутация НЕ разрешена (install-root вне
    /// канонизированного TEST_ROOT). Это «тест, целящийся в прод»: без взведённой защёлки
    /// оверрайды игнорируются и конвейер молча пошёл бы на ПРОД-URL/прод-label. Ловим и
    /// ГРОМКО отказываем стартовать (см. `runSync`). В проде (нет `TEST_MODE`) — всегда false,
    /// ветка недостижима, прод-поведение не меняется.
    var halfCockedTestLatch: Bool {
        guard config.env[CalibreTestLatch.testModeKey] == "1",
              let dmg = config.env[Self.dmgURLKey], !dmg.isEmpty else { return false }
        return !mutationAllowed
    }

    /// OS-гейт автоустановки (task 3.4). false → только ручная подача (D42).
    var autoInstallSupported: Bool {
        config.currentOS.majorVersion >= config.minAutoInstallMajorOS
    }

    // MARK: Разрешение URL/флагов (оверрайды — только под защёлкой)

    /// URL DMG: под защёлкой — оверрайд (любой scheme, тест); иначе прод (trust-gate у вызова).
    func effectiveDMGURL() -> (url: URL, isOverride: Bool) {
        if mutationAllowed, let s = config.env[Self.dmgURLKey], let u = URL(string: s) {
            return (u, true)
        }
        return (Self.productionDMGURL, false)
    }

    /// URL SHA-512: под защёлкой — оверрайд; иначе прод из версии. nil = версию не узнали.
    func effectiveSHAURL(version: String) -> (url: URL, isOverride: Bool)? {
        if mutationAllowed, let s = config.env[Self.sha512URLKey], let u = URL(string: s) {
            return (u, true)
        }
        guard !version.isEmpty, let u = URL(string: "\(Self.signatureBase)calibre-\(version).dmg.sha512") else {
            return nil
        }
        return (u, false)
    }

    /// Пропуск codesign — ТОЛЬКО под защёлкой (стаб-фикстура не подписана; живой e2e гоняет настоящий).
    var skipCodesign: Bool { mutationAllowed && config.env[Self.skipCodesignKey] == "1" }

    /// https + разрешённый хост (для скачивания артефактов, инв.10).
    static func isAllowedDownloadHost(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let h = url.host?.lowercased() else { return false }
        return allowedHosts.contains(h) || h.hasSuffix(allowedHostSuffix)
    }

    // MARK: Публичный запуск

    /// Внутренний сигнал остановки конвейера.
    private enum Stop: Error {
        case fail(InstallPhase.Reason)
        case cancelled
        case manual
    }

    /// Прогнать весь конвейер (блокирующе — вызывать с фонового потока; store делает это сам).
    /// `onPhase` зовётся на каждую смену фазы (может прийти с фонового/делегатного потока —
    /// обёртка обязана сама маршалить в UI-поток). Возвращает терминальную фазу.
    @discardableResult
    func runSync(onPhase: @escaping (InstallPhase) -> Void) -> InstallPhase {
        lock.lock(); cancelRequested = false; mountedDev = nil; lock.unlock()

        // Дополнение D-ревью 2026-07-21 (B1): полузведённая тест-защёлка (TEST_MODE=1 + задан
        // FB2_CALIBRE_DMG_URL, но install-root вне TEST_ROOT) → НЕ стартуем установку вообще,
        // чтобы не потянуть прод-URL/прод-label под видом теста. Громкий отказ, не тихий прод.
        // В проде ветка недостижима (нет TEST_MODE) — поведение не меняется.
        if halfCockedTestLatch {
            NSLog("fb2-to-epub: полузведённая тест-защёлка (FB2_CALIBRE_TEST_MODE=1 и задан FB2_CALIBRE_DMG_URL, но install-root вне FB2_CALIBRE_TEST_ROOT): отказываюсь ставить, чтобы не тянуть прод-URL/прод-label.")
            let t = InstallPhase.error(.install); onPhase(t); return t
        }

        let terminal: InstallPhase
        do {
            onPhase(.precheck)
            try precheckOS()
            try precheckDisk()

            let dl = try download(onPhase: onPhase)      // .downloading(...)
            try verifySHA(dmgPath: dl.dmgPath, version: dl.version)

            onPhase(.installing)
            let mnt = try mount(dmgPath: dl.dmgPath)     // ставит mountedDev
            try checkStagedSource(mountPoint: mnt)       // no-app / LSMinimumSystemVersion
            try stage(mountPoint: mnt)

            onPhase(.verifying)
            try verifyStaged()

            onPhase(.activating)
            try swap()

            terminal = .success
        } catch Stop.cancelled {
            cleanup()   // отмена случается на download (до mount): снимает частичное/mnt/staging
            onPhase(.idle); return .idle
        } catch Stop.manual {
            let t = InstallPhase.manual; onPhase(t); return t
        } catch Stop.fail(let reason) {
            cleanup()
            let t = InstallPhase.error(reason); onPhase(t); return t
        } catch {
            cleanup()
            let t = InstallPhase.error(.install); onPhase(t); return t
        }

        // success: снять dmg+mnt, calibre.app оставить.
        cleanup()
        onPhase(terminal)
        return terminal
    }

    /// Отмена: пометить + отменить активную загрузку (task.cancel → делегат разбудит конвейер).
    func cancel() {
        lock.lock(); cancelRequested = true; let t = currentTask; lock.unlock()
        t?.cancel()
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelRequested }

    // MARK: Шаги конвейера

    /// OS-гейт (D42): macOS < 14 → автоустановки нет.
    private func precheckOS() throws {
        if !autoInstallSupported { throw Stop.manual }
    }

    /// Диск (D41): том App Support ≥ порога. Каталог создаём заранее — тогда знаем том.
    private func precheckDisk() throws {
        try? fm.createDirectory(atPath: downloadsDir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: downloadsDir)
        guard let vals = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = vals.volumeAvailableCapacityForImportantUsage else {
            // Не смогли измерить — не блокируем на ложном срабатывании; дальше сеть/место всё равно поймают.
            return
        }
        if available < config.diskThresholdBytes { throw Stop.fail(.space) }
    }

    private struct Downloaded { let dmgPath: String; let version: String }

    /// Скачать DMG в downloads/calibre.dmg с прогрессом/отменой (СВОЯ реализация, не UpdateChecker).
    private func download(onPhase: @escaping (InstallPhase) -> Void) throws -> Downloaded {
        // m8: отмена, пришедшая во время precheck, не должна давать скачиванию стартовать.
        if isCancelled { throw Stop.cancelled }
        try? fm.createDirectory(atPath: downloadsDir, withIntermediateDirectories: true)
        try? fm.removeItem(atPath: dmgPath)

        let (url, isOverride) = effectiveDMGURL()
        if !isOverride {
            guard Self.isAllowedDownloadHost(url) else { throw Stop.fail(.network) }
        }

        var request = URLRequest(url: url)
        request.setValue("fb2-to-epub", forHTTPHeaderField: "User-Agent")   // GitHub 403 без UA
        request.timeoutInterval = config.networkTimeout

        let delegate = Downloader(destination: dmgPath,
                                  trustGate: isOverride ? nil : Self.isAllowedDownloadHost,
                                  onProgress: { got, total in onPhase(.downloading(got: got, total: total)) })
        let session = URLSession(configuration: config.session.configuration,
                                 delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let sem = DispatchSemaphore(value: 0)
        delegate.onComplete = { sem.signal() }

        let task = session.downloadTask(with: request)
        lock.lock(); currentTask = task; lock.unlock()
        task.resume()
        sem.wait()
        lock.lock(); currentTask = nil; lock.unlock()

        if isCancelled || delegate.wasCancelled {
            throw Stop.cancelled
        }
        if delegate.transportError != nil { throw Stop.fail(.network) }
        if let code = delegate.statusCode, !(200..<300).contains(code) { throw Stop.fail(.network) }
        guard delegate.moved,
              let size = fileSize(dmgPath), size >= config.minDownloadBytes else {
            throw Stop.fail(.network)
        }

        let version = extractVersion(suggested: delegate.suggestedFilename, finalURL: delegate.finalURL)
            ?? versionFromGitHubAPI()
            ?? ""
        guard !version.isEmpty else { throw Stop.fail(.install) }
        return Downloaded(dmgPath: dmgPath, version: version)
    }

    /// SHA-512 fail-closed: сверить сайдкар со стриминговым хешем DMG. Не сошлось/недоступен → снести DMG.
    private func verifySHA(dmgPath: String, version: String) throws {
        guard let (shaURL, isOverride) = effectiveSHAURL(version: version) else {
            try? fm.removeItem(atPath: dmgPath); throw Stop.fail(.install)
        }
        if !isOverride {
            guard Self.isAllowedDownloadHost(shaURL) else {
                try? fm.removeItem(atPath: dmgPath); throw Stop.fail(.install)
            }
        }
        guard let body = fetchText(shaURL, trustGate: isOverride ? nil : Self.isAllowedDownloadHost),
              let expected = body.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).first
                                 .map({ String($0).lowercased() }),
              expected.count == 128, isHex(expected) else {
            try? fm.removeItem(atPath: dmgPath); throw Stop.fail(.install)
        }
        guard let actual = streamSHA512(dmgPath), actual == expected else {
            try? fm.removeItem(atPath: dmgPath); throw Stop.fail(.install)
        }
    }

    /// hdiutil attach -plist в наш mountpoint; запомнить base-disk для detach.
    private func mount(dmgPath: String) throws -> String {
        try? fm.removeItem(atPath: mountPoint)
        try? fm.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)

        let r = Self.runProcess("/usr/bin/hdiutil",
                                ["attach", dmgPath, "-nobrowse", "-readonly", "-plist", "-mountpoint", mountPoint])
        guard r.rc == 0,
              let data = r.out.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any],
              let entities = dict["system-entities"] as? [[String: Any]] else {
            throw Stop.fail(.install)
        }
        let devs = entities.compactMap { $0["dev-entry"] as? String }
        guard let base = Self.baseDisk(devs) else { throw Stop.fail(.install) }
        lock.lock(); mountedDev = base; lock.unlock()
        return mountPoint
    }

    /// Пост-mount: есть ли calibre.app и не выше ли его LSMinimumSystemVersion текущей ОС (страховка OS-гейта).
    private func checkStagedSource(mountPoint: String) throws {
        let app = "\(mountPoint)/calibre.app"
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: app, isDirectory: &isDir), isDir.boolValue else {
            throw Stop.fail(.install)   // DMG без calibre.app
        }
        let info = "\(app)/Contents/Info.plist"
        if let data = fm.contents(atPath: info),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let lsmin = plist["LSMinimumSystemVersion"] as? String,
           versionExceedsCurrentOS(lsmin) {
            throw Stop.fail(.install)
        }
    }

    /// ditto смонтированного calibre.app → staging (снеся прежние остатки).
    private func stage(mountPoint: String) throws {
        try? fm.removeItem(atPath: stagingApp)
        try? fm.removeItem(atPath: oldApp)
        let r = Self.runProcess("/usr/bin/ditto", ["\(mountPoint)/calibre.app", stagingApp])
        guard r.rc == 0 else { throw Stop.fail(.install) }
    }

    /// Верификация staged-копии: codesign (кроме тест-режима) + exec --version + исполняемость CLI.
    private func verifyStaged() throws {
        if !skipCodesign {
            let r = Self.runProcess("/usr/bin/codesign", ["--verify", "--strict", "--deep", stagingApp])
            guard r.rc == 0 else { throw Stop.fail(.install) }
        }
        let convert = "\(stagingApp)/Contents/MacOS/ebook-convert"
        guard CalibreLocator.isExecutableRegularFile(convert) else { throw Stop.fail(.install) }
        let r = Self.runProcess(convert, ["--version"])
        guard r.rc == 0, versionLooksValid(r.out) else { throw Stop.fail(.install) }
        for cli in ["ebook-meta", "ebook-polish"] {
            guard CalibreLocator.isExecutableRegularFile("\(stagingApp)/Contents/MacOS/\(cli)") else {
                throw Stop.fail(.install)
            }
        }
    }

    /// Атомарный своп: calibre.app → .old, staging → calibre.app, снести .old.
    ///
    /// S1 (D-ревью): если ВТОРОЙ rename (staging → calibre.app) падает, а рабочая копия
    /// уже уехала в `.old`, откатываем `.old → calibre.app` ДО общей зачистки — иначе
    /// рабочий движок потерян (cleanup стирает staging, а следующий старт снёс бы `.old`).
    /// `.old` сносим ТОЛЬКО после успешного второго rename.
    private func swap() throws {
        let hadInstalled = fm.fileExists(atPath: installedApp)
        if hadInstalled {
            try? fm.removeItem(atPath: oldApp)
            try fm.moveItem(atPath: installedApp, toPath: oldApp)
        }
        do {
            if let hook = swapPromoteHook {
                try hook(stagingApp, installedApp)
            } else {
                try fm.moveItem(atPath: stagingApp, toPath: installedApp)
            }
        } catch {
            // Второй rename упал. Рабочая копия уже в .old, а calibre.app пуст → вернуть
            // .old на место ДО того, как runSync позовёт cleanup() (иначе движок потерян).
            if hadInstalled, !fm.fileExists(atPath: installedApp), fm.fileExists(atPath: oldApp) {
                try? fm.moveItem(atPath: oldApp, toPath: installedApp)
            }
            throw error
        }
        try? fm.removeItem(atPath: oldApp)
    }

    // MARK: Зачистка

    /// Снять монтирование (если было), убрать dmg/mnt/staging. calibre.app НЕ трогаем. Идемпотентно.
    private func cleanup() {
        lock.lock(); let dev = mountedDev; mountedDev = nil; lock.unlock()
        if let dev = dev { detach(dev: dev) }
        try? fm.removeItem(atPath: mountPoint)
        try? fm.removeItem(atPath: dmgPath)
        try? fm.removeItem(atPath: stagingApp)
    }

    /// detach по base-disk: ретраи 1с/2с/4с → -force. Неуспех НЕ фатален (зачистка на след. старте).
    private func detach(dev: String) {
        if Self.runProcess("/usr/bin/hdiutil", ["detach", dev]).rc == 0 { return }
        for delay in [1.0, 2.0, 4.0] {
            Thread.sleep(forTimeInterval: delay)
            if Self.runProcess("/usr/bin/hdiutil", ["detach", dev]).rc == 0 { return }
        }
        _ = Self.runProcess("/usr/bin/hdiutil", ["detach", dev, "-force"])
    }

    /// Зачистка остатков прошлого прогона (task 3.12; AppDelegate зовёт в init, фоново).
    /// Только внутри app-owned корня. Заблудившийся mnt best-effort размонтируем.
    static func cleanupLeftovers(home: String) {
        let fm = FileManager.default
        let root = CalibreLocator.appOwnedRoot(home: home)
        let mnt = "\(root)/downloads/mnt"
        if fm.fileExists(atPath: mnt) {
            _ = runProcess("/usr/bin/hdiutil", ["detach", mnt, "-force"])
        }

        // S1 (двойная авария): если calibre.app ОТСУТСТВУЕТ, а calibre.app.old — ВАЛИДЕН
        // (все 3 CLI), значит своп упал ПОСЛЕ первого rename (рабочая копия уехала в .old),
        // а до отката `.old → calibre.app` дело не дошло (напр. процесс убит между двумя
        // rename). Тогда `.old` — единственный рабочий движок: возвращаем его на место ВМЕСТО
        // сноса ниже. Штатные случаи (calibre.app на месте + остатки) не затронуты —
        // восстановление срабатывает ТОЛЬКО когда calibre.app отсутствует.
        let installed = "\(root)/calibre.app"
        let old = "\(root)/calibre.app.old"
        if !fm.fileExists(atPath: installed),
           CalibreLocator.isValid(macosDir: "\(old)/Contents/MacOS") {
            try? fm.moveItem(atPath: old, toPath: installed)
        }

        for p in ["calibre.app.installing", "calibre.app.old", "downloads/mnt", "downloads/calibre.dmg"] {
            try? fm.removeItem(atPath: "\(root)/\(p)")
        }
    }

    // MARK: Утилиты

    private func fileSize(_ path: String) -> Int64? {
        (try? fm.attributesOfItem(atPath: path)[.size] as? Int64) ?? nil
    }

    private func isHex(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isHexDigit }
    }

    /// Версия из `calibre-X.Y.Z.dmg` (имя файла или последний сегмент финального URL).
    private func extractVersion(suggested: String?, finalURL: URL?) -> String? {
        let re = try? NSRegularExpression(pattern: "calibre-(\\d+\\.\\d+\\.\\d+)\\.dmg")
        for c in [suggested, finalURL?.lastPathComponent].compactMap({ $0 }) {
            let range = NSRange(c.startIndex..., in: c)
            if let m = re?.firstMatch(in: c, options: [], range: range),
               let r = Range(m.range(at: 1), in: c) {
                return String(c[r])
            }
        }
        return nil
    }

    /// Фолбэк версии через GitHub API (метаданные, отдельный allow-host; см. риск в отчёте).
    private func versionFromGitHubAPI() -> String? {
        let url = Self.versionFallbackAPI
        guard url.scheme?.lowercased() == "https",
              let h = url.host?.lowercased(), Self.versionMetadataHosts.contains(h),
              // m7: редиректы гейтим на download-allow-хосты ИЛИ api-метаданные (симметрия с DMG).
              let body = fetchText(url, trustGate: { u in
                  Self.isAllowedDownloadHost(u)
                      || (u.scheme?.lowercased() == "https"
                          && Self.versionMetadataHosts.contains(u.host?.lowercased() ?? ""))
              }),
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return nil }
        // tag формата "v9.11.0" → "9.11.0"
        let re = try? NSRegularExpression(pattern: "(\\d+\\.\\d+\\.\\d+)")
        let range = NSRange(tag.startIndex..., in: tag)
        if let m = re?.firstMatch(in: tag, options: [], range: range), let r = Range(m.range(at: 1), in: tag) {
            return String(tag[r])
        }
        return nil
    }

    /// Вывод `ebook-convert --version` содержит версию вида X.Y(.Z).
    private func versionLooksValid(_ out: String) -> Bool {
        let re = try? NSRegularExpression(pattern: "\\d+\\.\\d+")
        let range = NSRange(out.startIndex..., in: out)
        return re?.firstMatch(in: out, options: [], range: range) != nil
    }

    /// `lsmin` (например "14.0") строго больше текущей ОС?
    private func versionExceedsCurrentOS(_ lsmin: String) -> Bool {
        let parts = lsmin.split(separator: ".").map { Int($0) ?? 0 }
        let major = parts.count > 0 ? parts[0] : 0
        let minor = parts.count > 1 ? parts[1] : 0
        let os = config.currentOS
        if major != os.majorVersion { return major > os.majorVersion }
        return minor > os.minorVersion
    }

    /// Стриминговый SHA-512 файла (чанки 4 МБ) → hex-строка (нижний регистр). nil при ошибке I/O.
    private func streamSHA512(_ path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        var hasher = SHA512Streaming()
        let chunk = 4 * 1024 * 1024
        while true {
            let data = fh.readData(ofLength: chunk)
            if data.isEmpty { break }
            hasher.update(data)
        }
        return hasher.finalizeHex()
    }

    /// Синхронный GET текста (для SHA-сайдкара / API). https+UA+таймаут; nil при сбое/не-2xx.
    /// m7: редиректы трест-гейтятся симметрично DMG-загрузке — `trustGate` рвёт переход на
    /// недоверенный хост (nil → редиректы свободны, как оверрайд DMG под защёлкой).
    private func fetchText(_ url: URL, trustGate: ((URL) -> Bool)? = nil) -> String? {
        var request = URLRequest(url: url)
        request.setValue("fb2-to-epub", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = config.networkTimeout
        let session = URLSession(configuration: config.session.configuration,
                                 delegate: RedirectGate(trustGate: trustGate), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var out: String?
        let sem = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            defer { sem.signal() }
            guard error == nil, let data = data else { return }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return }
            out = String(data: data, encoding: .utf8)
        }
        task.resume()
        sem.wait()
        return out
    }

    // MARK: Процессы

    /// Запустить внешний бинарь, дождаться, вернуть (rc, stdout+stderr). Для наших мелких выводов
    /// читаем до EOF затем waitUntilExit — без риска дедлока пайпа.
    @discardableResult
    static func runProcess(_ launchPath: String, _ args: [String]) -> (rc: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Base-disk (`/dev/diskN`) из списка dev-entry: самый короткий, без партиции.
    static func baseDisk(_ devs: [String]) -> String? {
        let re = try? NSRegularExpression(pattern: "^(/dev/disk[0-9]+)")
        for d in devs.sorted(by: { $0.count < $1.count }) {
            let range = NSRange(d.startIndex..., in: d)
            if let m = re?.firstMatch(in: d, options: [], range: range), let r = Range(m.range(at: 1), in: d) {
                return String(d[r])
            }
        }
        return nil
    }
}

// MARK: - Стриминговый SHA-512

/// Тонкая обёртка над CryptoKit.SHA512 (инкрементальный апдейт чанками, hex на выходе).
private struct SHA512Streaming {
    private var ctx = SHA512()
    mutating func update(_ data: Data) { ctx.update(data: data) }
    mutating func finalizeHex() -> String {
        ctx.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Делегат загрузки (прогресс + trust-gate редиректов + перенос файла)

/// URLSessionDownloadDelegate: копит байты (прогресс), переносит готовый файл в destination,
/// trust-gейтит редиректы (если задан gate) и будит конвейер по завершении.
private final class Downloader: NSObject, URLSessionDownloadDelegate {
    private let destination: String
    private let trustGate: ((URL) -> Bool)?
    private let onProgress: (Int64, Int64) -> Void

    var onComplete: (() -> Void)?
    private(set) var moved = false
    private(set) var suggestedFilename: String?
    private(set) var finalURL: URL?
    private(set) var statusCode: Int?
    private(set) var transportError: Error?
    private(set) var wasCancelled = false
    /// m4: последний опубликованный целый МБ (÷1_000_000) — троттлинг прогресса. -1 = ещё не публиковали.
    private var lastProgressMB: Int64 = -1

    init(destination: String, trustGate: ((URL) -> Bool)?, onProgress: @escaping (Int64, Int64) -> Void) {
        self.destination = destination
        self.trustGate = trustGate
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        // m4: троттлим публикацию — только при смене целого МБ (÷1_000_000, как в дисплее) или
        // на 100%, чтобы не будить UI тысячи раз за загрузку. Первый чанк публикуется всегда (-1).
        let mb = totalBytesWritten / 1_000_000
        let done = totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite
        guard mb != lastProgressMB || done else { return }
        lastProgressMB = mb
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let http = downloadTask.response as? HTTPURLResponse
        statusCode = http?.statusCode
        suggestedFilename = downloadTask.response?.suggestedFilename
        finalURL = downloadTask.response?.url ?? downloadTask.currentRequest?.url
        // Переносим СИНХРОННО: location валиден только внутри колбэка.
        let fm = FileManager.default
        let dst = URL(fileURLWithPath: destination)
        do {
            try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination) { try fm.removeItem(at: dst) }
            try fm.moveItem(at: location, to: dst)
            moved = true
        } catch {
            moved = false
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let err = error as? URLError, err.code == .cancelled {
            wasCancelled = true
        } else if let err = error {
            transportError = err
        }
        onComplete?()
    }

    /// Редиректы: держим trust-gate (calibre → github → githubusercontent). Оверрайд (gate=nil) — свободно.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let gate = trustGate else { completionHandler(request); return }
        if let url = request.url, gate(url) {
            var req = request
            req.setValue("fb2-to-epub", forHTTPHeaderField: "User-Agent")
            completionHandler(req)
        } else {
            transportError = URLError(.badServerResponse)
            completionHandler(nil)   // оборвать недоверенный редирект
        }
    }
}

// MARK: - Гейт редиректов для текстовых GET (m7)

/// URLSessionTaskDelegate ТОЛЬКО ради trust-gate редиректов для `fetchText` (SHA-сайдкар,
/// version-API) — симметрия с DMG-загрузкой (Downloader). Недоверенный редирект обрывается;
/// `trustGate == nil` → редиректы свободны (оверрайд под защёлкой, как у DMG).
private final class RedirectGate: NSObject, URLSessionTaskDelegate {
    private let trustGate: ((URL) -> Bool)?
    init(trustGate: ((URL) -> Bool)?) { self.trustGate = trustGate }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let gate = trustGate else { completionHandler(request); return }
        if let url = request.url, gate(url) {
            var req = request
            req.setValue("fb2-to-epub", forHTTPHeaderField: "User-Agent")
            completionHandler(req)
        } else {
            completionHandler(nil)   // оборвать недоверенный редирект (fail-closed)
        }
    }
}

// MARK: - InstallStore: UI-обёртка (владелец — AppDelegate; сшивка в CAL-4)

/// Тонкий ObservableObject поверх движка: @Published-фаза, re-entry guard, взаимоисключение с
/// авто-апдейтом приложения. Сам конвейер НЕ дублирует — делегирует `CalibreInstaller`.
///
/// CAL-4: store — это «мозг» онбординга для UI. Прод-init связывает конвейер (`CalibreInstaller`)
/// с ОЖИВЛЕНИЕМ АГЕНТА (`activate`, реально это installer.sh: bootout→bootstrap→enable→kickstart):
///   • `start()`   — полный путь: скачать→проверить→поставить→(движок на месте)→ОЖИВИТЬ агента.
///     Пока идёт активация, показываем `.verifying` («Проверяю движок…», спека). Успех активации →
///     `.success`; движок встал, а агент не поднялся → `.agentActivationFailed` (≠ провал установки).
///   • `activateOnly()` — повтор ТОЛЬКО активации, без повторного скачивания (кнопки «Повторить
///     запуск агента» / «Проверить снова», когда движок уже найден).
///   • `showManual()` / `reset()` — чисто UI-переходы (ручная подача · возврат к бейджу).
///
/// Файл Foundation-only: маппинг `InstallPhase → EngineSetupCard.Phase` живёт на SwiftUI-стороне
/// (EngineSetupCard.from), чтобы headless-тест конвейера не тянул SwiftUI.
///
/// Тест-init (`runner:`) остаётся для проверки guard/взаимоисключения без сети.
final class InstallStore: ObservableObject {

    @Published private(set) var phase: InstallPhase = .idle

    /// Выставляется авто-апдейтером приложения: пока идёт апдейт, установку движка не начинаем.
    var isUpdateInFlight = false

    /// Поддерживает ли ОС автоустановку (OS-гейт D42). UI берёт отсюда «idle-подачу» без движка:
    /// modern → notInstalled (кнопка «Установить»), старая → сразу manual(osUnsupported).
    let autoInstallSupported: Bool

    private let lock = NSLock()
    private var running = false

    private let installer: CalibreInstaller?
    /// Оживление агента (installer.sh) ПОСЛЕ того, как движок лёг. true = агент поднялся.
    /// Прод: замыкание на EngineClient (AppDelegate). Тест-init: стаб.
    private let activate: () -> Bool
    /// Функция запуска: (сообщать фазу, сигнал завершения). Прод — движок+активация; тест — стаб.
    private let runner: (@escaping (InstallPhase) -> Void, @escaping () -> Void) -> Void

    /// Прод-инициализатор: конвейер из конфига + оживление агента. После терминального `.success`
    /// конвейера (движок на месте) НЕ публикуем success сразу — держим `.verifying` и запускаем
    /// `activate()`; финал — `.success` или `.agentActivationFailed`. Иные терминалы конвейера
    /// (error/idle/manual) конвейер публикует сам.
    init(config: CalibreInstaller.Config,
         autoInstallSupported: Bool? = nil,
         activate: @escaping () -> Bool = { true }) {
        let engine = CalibreInstaller(config: config)
        self.installer = engine
        self.autoInstallSupported = autoInstallSupported ?? engine.autoInstallSupported
        self.activate = activate
        self.runner = { publish, done in
            DispatchQueue.global(qos: .userInitiated).async {
                // Подавляем внутренний `.success` конвейера: движок лёг, но агент ещё не оживлён.
                // Последняя опубликованная in-flight фаза — `.activating` (своп) → UI держит
                // «Проверяю движок…», пока идёт installer.sh.
                let terminal = engine.runSync { p in
                    if p != .success { publish(p) }
                }
                if terminal == .success {
                    let ok = activate()
                    publish(ok ? .success : .agentActivationFailed)
                }
                done()
            }
        }
    }

    /// Тест-инициализатор: произвольный runner (без сети), для проверки guard/взаимоисключения.
    init(runner: @escaping (@escaping (InstallPhase) -> Void, @escaping () -> Void) -> Void) {
        self.installer = nil
        self.activate = { false }
        self.autoInstallSupported = true
        self.runner = runner
    }

    /// Полный старт: скачать→проверить→поставить→оживить. re-entry guard + взаимоисключение с
    /// авто-апдейтом. Возвращает false, если установка уже идёт или идёт апдейт приложения.
    @discardableResult
    func start() -> Bool {
        lock.lock()
        if running || isUpdateInFlight { lock.unlock(); return false }
        running = true
        lock.unlock()

        runner({ [weak self] p in self?.publish(p) },
               { [weak self] in
                   guard let self = self else { return }
                   self.lock.lock(); self.running = false; self.lock.unlock()
               })
        return true
    }

    /// Повтор ТОЛЬКО оживления агента (без скачивания): «Повторить запуск агента»
    /// (`agentActivationFailed`) и «Проверить снова», когда движок уже найден (task 4.2/4.4).
    /// Показывает `.verifying` на время попытки → `.success` / `.agentActivationFailed`.
    @discardableResult
    func activateOnly() -> Bool {
        lock.lock()
        if running || isUpdateInFlight { lock.unlock(); return false }
        running = true
        lock.unlock()

        publish(.verifying)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let ok = self.activate()
            self.publish(ok ? .success : .agentActivationFailed)
            self.lock.lock(); self.running = false; self.lock.unlock()
        }
        return true
    }

    /// Ручная подача (тап «Установить вручную»): чистый UI-переход, ничего не запускает.
    func showManual() { publish(.manual) }

    /// Вернуть к «бейджу» (idle): после success-нормализации / когда экран перечитал движок.
    func reset() { publish(.idle) }

    /// Идёт ли установка прямо сейчас (для UI/тестов).
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    /// D40: мутирующая работа в полёте (окно нельзя рвать → terminate-политика).
    var isInFlight: Bool { phase.isInFlight }

    func cancel() { installer?.cancel() }

    /// Обновление @Published строго на main (SwiftUI); в headless-тесте main-loop не крутится —
    /// но тест guard'а на @Published не смотрит, а проверяет возврат start()/isRunning.
    private func publish(_ p: InstallPhase) {
        if Thread.isMainThread { phase = p }
        else { DispatchQueue.main.async { [weak self] in self?.phase = p } }
    }
}
