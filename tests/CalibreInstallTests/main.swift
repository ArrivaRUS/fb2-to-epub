// main.swift — интеграционные тесты конвейера CalibreInstaller (CAL-3, app/CalibreInstaller.swift).
//
// ЧТО ПОД ТЕСТОМ (реальный движок, fixture-DMG, БЕЗ сети наружу и БЕЗ 330 МБ):
//   happy path (движок лёг, локатор видит app-owned, повторный запуск идемпотентен)
//   + негативы 3.14:
//     · битый sha            — сайдкар с чужим хешем → .error(.install), DMG стёрт
//     · DMG без calibre.app  — → .error(.install), чисто
//     · verify-fail          — стаб ebook-convert rc≠0 → .error(.install), staging снесён
//     · нет места            — порог диска ↑ → .error(.space), ничего не скачано
//     · отмена на середине   — cancel() на прогрессе → .idle, частичное стёрто
//     · LSMinimumSystemVersion выше ОС → .error(.install)
//     · защёлка выключена    — env-оверрайды игнорируются (прод-пути)
//   + служебное: OS-гейт (D42) → .manual · cleanupLeftovers · re-entry guard InstallStore.
//
// ИЗОЛЯЦИЯ: HOME/TEST_ROOT — throwaway (mktemp) под защёлкой (FB2_CALIBRE_TEST_MODE=1). DMG/SHA
// раздаёт локальный HTTP-сервер (127.0.0.1, троттлинг — окно для отмены + многочанковый SHA-стрим),
// поднятый раннером; URL приходят в env. codesign в тест-режиме заменён маркером под защёлкой
// (стаб не подписан). Ничего не пишется вне TEST_ROOT; реальный ~/Library и launchd не трогаются.

import Foundation

// MARK: - Крошечный TAP-раннер (стиль ClearHistoryTests / CalibreLocatorTests)

final class T {
    static var passed = 0
    static var failed = 0
    static var current = "<none>"

    static func ok(_ cond: @autoclosure () -> Bool, _ msg: String) {
        if cond() { passed += 1; print("  ok   - \(msg)") }
        else { failed += 1; print("  FAIL - \(msg)   [in: \(current)]") }
    }
    static func eq<V: Equatable>(_ a: V, _ b: V, _ msg: String) {
        ok(a == b, "\(msg)  (got: \(a), want: \(b))")
    }
    static func run(_ name: String, _ body: () -> Void) {
        current = name; print("# \(name)"); body()
    }
}

// MARK: - Окружение раннера

let ENV = ProcessInfo.processInfo.environment
let SERVER = ENV["FB2_TEST_SERVER"] ?? ""
let VER = ENV["FB2_TEST_VER"] ?? "9.11.0"
let TEST_ROOT = ENV["FB2_CALIBRE_TEST_ROOT"] ?? ""
let REPO = ENV["FB2_REPO_DIR"] ?? ""   // CAL-4: путь к packaging/installer.sh для теста активации
let FM = FileManager.default

func dmgURL(_ variant: String) -> String { "\(SERVER)/\(variant)/calibre-\(VER).dmg" }
func shaURL(_ variant: String) -> String { "\(SERVER)/\(variant)/calibre-\(VER).dmg.sha512" }
let BAD_SHA_URL = "\(SERVER)/bad.sha512"

// MARK: - Хелперы

/// Свежий изолированный HOME под TEST_ROOT (install-root окажется внутри → защёлка мутации взведена).
func freshHome(_ tag: String) -> String {
    let h = "\(TEST_ROOT)/home-\(tag)-\(UUID().uuidString.prefix(6))"
    try? FM.createDirectory(atPath: h, withIntermediateDirectories: true)
    return h
}

/// Конфиг «живого» прогона: оверрайды DMG/SHA + пропуск codesign (под защёлкой), маленькие пороги.
func liveConfig(home: String,
                dmg: String,
                sha: String,
                disk: Int64 = 1,
                minDL: Int64 = 1_000_000,
                os: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
                skipCodesign: Bool = true) -> CalibreInstaller.Config {
    var env = ENV
    env[CalibreInstaller.dmgURLKey] = dmg
    env[CalibreInstaller.sha512URLKey] = sha
    if skipCodesign { env[CalibreInstaller.skipCodesignKey] = "1" }
    var c = CalibreInstaller.Config(home: home, env: env)
    c.diskThresholdBytes = disk
    c.minDownloadBytes = minDL
    c.currentOS = os
    return c
}

/// Прогнать конвейер, вернуть терминальную фазу и лог фаз. `onEach` — для отмены на прогрессе.
@discardableResult
func drive(_ inst: CalibreInstaller, onEach: ((InstallPhase) -> Void)? = nil)
    -> (terminal: InstallPhase, log: [InstallPhase]) {
    let lock = NSLock()
    var log: [InstallPhase] = []
    let terminal = inst.runSync { p in
        lock.lock(); log.append(p); lock.unlock()
        onEach?(p)
    }
    return (terminal, log)
}

func exists(_ p: String) -> Bool { FM.fileExists(atPath: p) }

/// downloads без «мусора»: ни calibre.dmg, ни mnt (пустая папка допустима).
func downloadsClean(_ inst: CalibreInstaller) -> Bool {
    !exists(inst.dmgPath) && !exists(inst.mountPoint)
}
func noStaging(_ inst: CalibreInstaller) -> Bool {
    !exists(inst.stagingApp) && !exists(inst.oldApp)
}

func waitUntil(_ cond: () -> Bool, _ timeout: TimeInterval) {
    let deadline = Date().addingTimeInterval(timeout)
    while !cond() && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
}

// MARK: - CAL-4 хелперы (сшивка: активация агента, InstallStore-оркестрация)

/// Гонять main-runloop, пока store не завершится (InstallStore публикует фазы через
/// DispatchQueue.main — в headless-раннере их надо СЛИВАТЬ, иначе @Published не двигается).
/// Ждём `!isRunning`, затем добираем очередь публикаций и возвращаем терминальную фазу.
func waitForTerminal(_ store: InstallStore, timeout: TimeInterval = 60) -> InstallPhase {
    let deadline = Date().addingTimeInterval(timeout)
    while store.isRunning && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    let flush = Date().addingTimeInterval(0.2)   // слить финальный publish(...)
    while Date() < flush {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    return store.phase
}

/// Положить фикстурный `calibre.app` (3 исполняемых стаб-CLI) в app-owned корень `home`,
/// чтобы installer.sh детектил его как app-owned (без mount/330 МБ).
func placeFixtureCalibre(_ home: String) {
    let macos = "\(CalibreLocator.appOwnedRoot(home: home))/calibre.app/Contents/MacOS"
    try? FM.createDirectory(atPath: macos, withIntermediateDirectories: true)
    for cli in CalibreLocation.requiredCLIs {
        let stub = "#!/bin/bash\ncase \"$1\" in\n  --version) echo \"\(cli) (calibre \(VER))\"; exit 0 ;;\n  *) exit 0 ;;\nesac\n"
        FM.createFile(atPath: "\(macos)/\(cli)", contents: stub.data(using: .utf8),
                      attributes: [.posixPermissions: 0o755])
    }
}

/// Прочитать одно типизированное значение из plist через plutil (как читает приложение).
func plistRaw(_ keypath: String, _ plistPath: String) -> String? {
    let r = CalibreInstaller.runProcess("/usr/bin/plutil", ["-extract", keypath, "raw", "-o", "-", plistPath])
    guard r.rc == 0 else { return nil }
    return r.out.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Живой happy-path + идемпотентность

func test_happy() {
    let home = freshHome("happy")
    let inst = CalibreInstaller(config: liveConfig(home: home, dmg: dmgURL("happy"), sha: shaURL("happy")))

    let (term, log) = drive(inst)
    T.eq(term, .success, "happy → success")
    T.ok(log.contains(.precheck), "прошла фаза precheck")
    T.ok(log.contains(where: { if case .downloading = $0 { return true }; return false }), "были фазы downloading")
    T.ok(log.contains(.verifying), "прошла фаза verifying")
    T.ok(log.contains(.activating), "прошла фаза activating")
    T.ok(exists(inst.installedApp), "calibre.app на месте")
    T.ok(downloadsClean(inst), "downloads чист (dmg/mnt убраны)")
    T.ok(noStaging(inst), "staging/.old убраны")

    // Локатор видит app-owned (порядок кандидатов: app-owned раньше системного).
    let loc = CalibreLocator.resolve(home: home, env: inst.config.env)
    T.ok(loc != nil, "локатор нашёл движок")
    T.eq(loc?.kind, .appOwned, "kind = appOwned")

    // Идемпотентность: повторный запуск (свежий движок поверх существующего) снова success, без мусора.
    let inst2 = CalibreInstaller(config: liveConfig(home: home, dmg: dmgURL("happy"), sha: shaURL("happy")))
    let (term2, _) = drive(inst2)
    T.eq(term2, .success, "повторный запуск → success (идемпотентно)")
    T.ok(exists(inst2.installedApp), "calibre.app всё ещё на месте")
    T.ok(downloadsClean(inst2), "downloads чист после повтора")
    T.ok(noStaging(inst2), "нет staging-остатков после повтора")
}

// MARK: - Негатив: битый SHA

func test_badSHA() {
    let home = freshHome("badsha")
    let inst = CalibreInstaller(config: liveConfig(home: home, dmg: dmgURL("happy"), sha: BAD_SHA_URL))
    let (term, _) = drive(inst)
    T.eq(term, .error(.install), "битый sha → error(.install)")
    T.ok(!exists(inst.dmgPath), "DMG стёрт после несовпадения sha")
    T.ok(downloadsClean(inst), "downloads чист")
    T.ok(!exists(inst.installedApp), "движок НЕ установлен")
    T.ok(noStaging(inst), "нет staging")
}

// MARK: - Негатив: DMG без calibre.app

func test_noApp() {
    let home = freshHome("noapp")
    let inst = CalibreInstaller(config: liveConfig(home: home, dmg: dmgURL("noapp"), sha: shaURL("noapp")))
    let (term, _) = drive(inst)
    T.eq(term, .error(.install), "DMG без calibre.app → error(.install)")
    T.ok(downloadsClean(inst), "downloads чист (dmg удалён, mnt размонтирован)")
    T.ok(!exists(inst.installedApp), "движок НЕ установлен")
    T.ok(noStaging(inst), "нет staging")
}

// MARK: - Негатив: verify-fail (ebook-convert rc≠0)

func test_verifyFail() {
    let home = freshHome("vf")
    let inst = CalibreInstaller(config: liveConfig(home: home, dmg: dmgURL("brokencli"), sha: shaURL("brokencli")))
    let (term, _) = drive(inst)
    T.eq(term, .error(.install), "verify-fail → error(.install)")
    T.ok(noStaging(inst), "staging снесён после провала verify")
    T.ok(downloadsClean(inst), "downloads чист")
    T.ok(!exists(inst.installedApp), "движок НЕ установлен")
}

// MARK: - Негатив: нет места (порог диска ↑)

func test_noSpace() {
    let home = freshHome("space")
    // Порог заведомо выше любого реального тома → .error(.space) ДО скачивания.
    let inst = CalibreInstaller(config: liveConfig(home: home, dmg: dmgURL("happy"), sha: shaURL("happy"),
                                                   disk: 100_000_000_000_000))
    let (term, log) = drive(inst)
    T.eq(term, .error(.space), "нет места → error(.space)")
    T.ok(!log.contains(where: { if case .downloading = $0 { return true }; return false }),
         "скачивание НЕ начиналось")
    T.ok(!exists(inst.dmgPath), "DMG не качался")
    T.ok(!exists(inst.installedApp), "движок НЕ установлен")
}

// MARK: - Негатив: отмена на середине

func test_cancel() {
    let home = freshHome("cancel")
    let inst = CalibreInstaller(config: liveConfig(home: home, dmg: dmgURL("happy"), sha: shaURL("happy")))
    var fired = false
    let (term, _) = drive(inst) { p in
        if case let .downloading(got, total) = p, got > 0, (total <= 0 || got < total), !fired {
            fired = true
            inst.cancel()
        }
    }
    T.ok(fired, "успели вызвать cancel() на фазе downloading")
    T.eq(term, .idle, "отмена → idle")
    T.ok(downloadsClean(inst), "частичное стёрто (downloads чист)")
    T.ok(!exists(inst.installedApp), "движок НЕ установлен")
}

// MARK: - Негатив: LSMinimumSystemVersion выше ОС

func test_highOS() {
    let home = freshHome("highos")
    // Фикстура highos собрана с LSMinimumSystemVersion=99.0 → выше текущей ОС.
    let inst = CalibreInstaller(config: liveConfig(home: home, dmg: dmgURL("highos"), sha: shaURL("highos")))
    let (term, _) = drive(inst)
    T.eq(term, .error(.install), "LSMinimumSystemVersion выше ОС → error(.install)")
    T.ok(downloadsClean(inst), "downloads чист")
    T.ok(!exists(inst.installedApp), "движок НЕ установлен")
    T.ok(noStaging(inst), "нет staging")
}

// MARK: - S1 (D-ревью): провал второго rename свопа → откат .old, рабочий движок не потерян

func test_swapSecondRenameRollback() {
    let home = freshHome("swaproll")
    // 1) Настоящая happy-установка → рабочий движок v1 на месте.
    let inst1 = CalibreInstaller(config: liveConfig(home: home, dmg: dmgURL("happy"), sha: shaURL("happy")))
    T.eq(drive(inst1).terminal, .success, "предзаливка: happy → success (движок v1)")
    T.ok(exists(inst1.installedApp), "движок v1 на месте")

    // 2) Вторая установка со СБОЕМ второго rename свопа (hook бросает). Рабочая копия уже
    //    уехала в .old → откат обязан вернуть её в calibre.app ДО общей зачистки.
    let inst2 = CalibreInstaller(config: liveConfig(home: home, dmg: dmgURL("happy"), sha: shaURL("happy")))
    inst2.swapPromoteHook = { _, _ in throw NSError(domain: "test.swap", code: 1) }
    let (term2, _) = drive(inst2)
    T.eq(term2, .error(.install), "провал второго rename → error(.install)")
    T.ok(exists(inst2.installedApp), "рабочий движок ВОССТАНОВЛЕН (.old → calibre.app)")
    T.ok(CalibreLocator.isValid(macosDir: "\(inst2.installedApp)/Contents/MacOS"),
         "восстановленный движок валиден (3 CLI на месте)")
    T.ok(!exists(inst2.oldApp), ".old убран после отката")
    T.ok(downloadsClean(inst2), "downloads чист (dmg/mnt убраны)")
    T.eq(CalibreLocator.resolve(home: home, env: inst2.config.env)?.kind, .appOwned,
         "после отката локатор всё ещё видит app-owned движок")
}

// MARK: - Защёлка (урок 015 / task 3.2): без TEST_MODE оверрайды игнорируются

func test_latchOff() {
    let home = freshHome("latchoff")
    var env = ENV
    env.removeValue(forKey: CalibreTestLatch.testModeKey)   // защёлка снята
    env[CalibreInstaller.dmgURLKey] = dmgURL("happy")
    env[CalibreInstaller.sha512URLKey] = shaURL("happy")
    env[CalibreInstaller.skipCodesignKey] = "1"
    let inst = CalibreInstaller(config: CalibreInstaller.Config(home: home, env: env))

    T.ok(!inst.mutationAllowed, "без TEST_MODE защёлка мутации НЕ взведена")
    T.eq(inst.effectiveDMGURL().url, CalibreInstaller.productionDMGURL, "DMG-оверрайд игнорируется → прод URL")
    T.ok(!inst.effectiveDMGURL().isOverride, "…и помечен как не-оверрайд")
    let sha = inst.effectiveSHAURL(version: VER)
    T.eq(sha?.url.absoluteString,
         "https://calibre-ebook.com/signatures/calibre-\(VER).dmg.sha512",
         "SHA-оверрайд игнорируется → прод URL из версии")
    T.ok(!(sha?.isOverride ?? true), "SHA помечен как не-оверрайд")
    T.ok(!inst.skipCodesign, "skipCodesign игнорируется без защёлки")
}

// MARK: - Защёлка: install-root ВНЕ TEST_ROOT → мутация запрещена даже при TEST_MODE

func test_latchOutsideRoot() {
    // env под защёлкой (TEST_MODE=1 + TEST_ROOT), но home вне TEST_ROOT.
    let outside = "/private/tmp/fb2-outside-\(UUID().uuidString.prefix(6))"
    try? FM.createDirectory(atPath: outside, withIntermediateDirectories: true)
    let inst = CalibreInstaller(config: CalibreInstaller.Config(home: outside, env: ENV))
    T.ok(!inst.mutationAllowed, "install-root вне TEST_ROOT → мутация запрещена (урок 015)")
    T.eq(inst.effectiveDMGURL().url, CalibreInstaller.productionDMGURL, "оверрайд не применяется вне TEST_ROOT")
    try? FM.removeItem(atPath: outside)

    // Контроль: home ВНУТРИ TEST_ROOT → мутация разрешена.
    let inside = freshHome("inside")
    let inst2 = CalibreInstaller(config: liveConfig(home: inside, dmg: dmgURL("happy"), sha: shaURL("happy")))
    T.ok(inst2.mutationAllowed, "install-root внутри TEST_ROOT → мутация разрешена")
    T.ok(inst2.effectiveDMGURL().isOverride, "…и оверрайд DMG применён")
}

// MARK: - B1 (D-ревью): полузведённая защёлка → громкий отказ, не тихий прод

func test_halfCockedLatch() {
    // TEST_MODE=1 + задан FB2_CALIBRE_DMG_URL, но install-root ВНЕ TEST_ROOT → мутация
    // запрещена. Это «тест, целящийся в прод»: конвейер обязан ГРОМКО отказать и НЕ стартовать
    // (иначе молча пошёл бы на прод-URL/прод-label).
    let outside = "/private/tmp/fb2-halfcock-\(UUID().uuidString.prefix(6))"
    try? FM.createDirectory(atPath: outside, withIntermediateDirectories: true)
    defer { try? FM.removeItem(atPath: outside) }
    var env = ENV
    env[CalibreInstaller.dmgURLKey] = dmgURL("happy")
    env[CalibreInstaller.sha512URLKey] = shaURL("happy")
    let inst = CalibreInstaller(config: CalibreInstaller.Config(home: outside, env: env))

    T.ok(!inst.mutationAllowed, "install-root вне TEST_ROOT → мутация запрещена")
    T.ok(inst.halfCockedTestLatch, "полузведённая защёлка распознана")
    let (term, log) = drive(inst)
    T.eq(term, .error(.install), "полузведённая защёлка → error(.install), установка не стартовала")
    T.ok(!log.contains(.precheck), "precheck не выполнялся (отказ до старта)")
    T.ok(!log.contains(where: { if case .downloading = $0 { return true }; return false }), "скачивания не было")
    T.ok(!exists(inst.dmgPath), "DMG не качался")
    T.ok(!exists(inst.installedApp), "движок НЕ установлен")

    // Контроль: тот же набор env, но install-root ВНУТРИ TEST_ROOT → защёлка полноценна.
    let inside = freshHome("halfcock-ok")
    let ok = CalibreInstaller(config: liveConfig(home: inside, dmg: dmgURL("happy"), sha: shaURL("happy")))
    T.ok(!ok.halfCockedTestLatch, "install-root внутри TEST_ROOT → защёлка полноценна, не полузведена")
}

// MARK: - OS-гейт (D42): macOS < 14 → .manual, ничего не скачано

func test_osGate() {
    let home = freshHome("osgate")
    let old = OperatingSystemVersion(majorVersion: 13, minorVersion: 6, patchVersion: 0)
    let inst = CalibreInstaller(config: liveConfig(home: home, dmg: dmgURL("happy"), sha: shaURL("happy"), os: old))
    T.ok(!inst.autoInstallSupported, "autoInstallSupported=false на macOS 13")
    let (term, log) = drive(inst)
    T.eq(term, .manual, "macOS < 14 → manual")
    T.ok(!log.contains(where: { if case .downloading = $0 { return true }; return false }), "скачивания не было")
    T.ok(!exists(inst.dmgPath), "DMG не качался")
}

// MARK: - Стартовая зачистка остатков (task 3.12), настоящий calibre.app не тронут

func test_cleanupLeftovers() {
    let home = freshHome("leftovers")
    let root = CalibreLocator.appOwnedRoot(home: home)
    let downloads = "\(root)/downloads"
    try? FM.createDirectory(atPath: "\(root)/calibre.app.installing/Contents/MacOS", withIntermediateDirectories: true)
    try? FM.createDirectory(atPath: "\(root)/calibre.app.old", withIntermediateDirectories: true)
    try? FM.createDirectory(atPath: "\(downloads)/mnt", withIntermediateDirectories: true)
    FM.createFile(atPath: "\(downloads)/calibre.dmg", contents: Data([0,1,2]))
    // Настоящий установленный движок ДОЛЖЕН пережить зачистку.
    try? FM.createDirectory(atPath: "\(root)/calibre.app/Contents/MacOS", withIntermediateDirectories: true)
    FM.createFile(atPath: "\(root)/calibre.app/Contents/MacOS/ebook-convert", contents: Data([0]))

    CalibreInstaller.cleanupLeftovers(home: home)

    T.ok(!exists("\(root)/calibre.app.installing"), "снесён calibre.app.installing")
    T.ok(!exists("\(root)/calibre.app.old"), "снесён calibre.app.old")
    T.ok(!exists("\(downloads)/mnt"), "снесён downloads/mnt")
    T.ok(!exists("\(downloads)/calibre.dmg"), "снесён downloads/calibre.dmg")
    T.ok(exists("\(root)/calibre.app/Contents/MacOS/ebook-convert"), "настоящий calibre.app НЕ тронут")
}

// MARK: - InstallStore: re-entry guard + взаимоисключение с авто-апдейтом (DoD)

func test_installStoreGuard() {
    // A. Пока идёт установка — второй start отбивается.
    let up = DispatchSemaphore(value: 0)
    let block = DispatchSemaphore(value: 0)
    let storeA = InstallStore(runner: { onPhase, done in
        DispatchQueue.global().async {
            onPhase(.downloading(got: 1, total: 2))
            up.signal()
            block.wait()
            done()
        }
    })
    T.ok(storeA.start(), "A: первый start → true")
    up.wait()
    T.ok(!storeA.start(), "A: второй start во время работы → false (re-entry guard)")
    block.signal()
    waitUntil({ !storeA.isRunning }, 2.0)
    T.ok(!storeA.isRunning, "A: guard сброшен после завершения")

    // B. После завершения start снова доступен.
    let storeB = InstallStore(runner: { onPhase, done in
        DispatchQueue.global().async { onPhase(.success); done() }
    })
    T.ok(storeB.start(), "B: первый start → true")
    waitUntil({ !storeB.isRunning }, 2.0)
    T.ok(storeB.start(), "B: повторный start после завершения → true")
    waitUntil({ !storeB.isRunning }, 2.0)

    // C. Идёт авто-апдейт приложения → установку движка не начинаем.
    let storeC = InstallStore(runner: { onPhase, done in
        DispatchQueue.global().async { onPhase(.success); done() }
    })
    storeC.isUpdateInFlight = true
    T.ok(!storeC.start(), "C: апдейт приложения в полёте → start отбит")
    storeC.isUpdateInFlight = false
    T.ok(storeC.start(), "C: апдейт снят → start проходит")
    waitUntil({ !storeC.isRunning }, 2.0)
}

// MARK: - CAL-4: InstallStore-оркестрация (конвейер → оживление агента)

/// Полный конвейер (fixture) → активация УДАЛАСЬ → финал .success, движок на месте.
func test_chainSuccess() {
    let home = freshHome("chain-ok")
    var activated = false
    let store = InstallStore(config: liveConfig(home: home, dmg: dmgURL("happy"), sha: shaURL("happy")),
                             activate: { activated = true; return true })
    T.ok(store.start(), "start() → true")
    let term = waitForTerminal(store)
    T.eq(term, .success, "конвейер+активация → success")
    T.ok(activated, "activate() вызван после укладки движка")
    T.ok(exists("\(CalibreLocator.appOwnedRoot(home: home))/calibre.app"), "calibre.app на месте")
    T.ok(!store.isInFlight, "по завершении не in-flight")
}

/// Движок лёг, но активация агента ПРОВАЛИЛАСЬ → .agentActivationFailed (≠ провал установки);
/// движок остаётся на месте (чинить надо только запуск агента — «Повторить запуск агента»).
func test_chainAgentFail() {
    let home = freshHome("chain-agentfail")
    let store = InstallStore(config: liveConfig(home: home, dmg: dmgURL("happy"), sha: shaURL("happy")),
                             activate: { false })
    T.ok(store.start(), "start() → true")
    let term = waitForTerminal(store)
    T.eq(term, .agentActivationFailed, "движок есть, агент не встал → agentActivationFailed")
    T.ok(exists("\(CalibreLocator.appOwnedRoot(home: home))/calibre.app"),
         "движок ОСТАЁТСЯ (провал ≠ снос движка)")
}

/// activateOnly(): повтор ТОЛЬКО активации без скачивания (кнопки «Повторить запуск агента» /
/// «Проверить снова»). true → .success; false → .agentActivationFailed; re-entry отбит.
func test_activateOnly() {
    let home = freshHome("actonly-ok")
    let ok = InstallStore(config: liveConfig(home: home, dmg: dmgURL("happy"), sha: shaURL("happy")),
                          activate: { true })
    T.ok(ok.activateOnly(), "activateOnly() → true (стартовал)")
    T.eq(waitForTerminal(ok), .success, "activateOnly happy → success")

    let home2 = freshHome("actonly-fail")
    let bad = InstallStore(config: liveConfig(home: home2, dmg: dmgURL("happy"), sha: shaURL("happy")),
                           activate: { false })
    T.ok(bad.activateOnly(), "activateOnly() → true (стартовал)")
    T.eq(waitForTerminal(bad), .agentActivationFailed, "activateOnly fail → agentActivationFailed")

    // re-entry: второй activateOnly во время работы отбит.
    let home3 = freshHome("actonly-reentry")
    let slow = InstallStore(config: liveConfig(home: home3, dmg: dmgURL("happy"), sha: shaURL("happy")),
                            activate: { Thread.sleep(forTimeInterval: 0.3); return true })
    T.ok(slow.activateOnly(), "первый activateOnly → true")
    T.ok(!slow.activateOnly(), "второй activateOnly во время работы → false (guard)")
    _ = waitForTerminal(slow)
}

/// showManual() / reset() — чистые UI-переходы (вызов с main-потока → publish синхронно).
func test_showManualReset() {
    let home = freshHome("manual")
    let store = InstallStore(config: liveConfig(home: home, dmg: dmgURL("happy"), sha: shaURL("happy")),
                             activate: { true })
    store.showManual()
    T.eq(store.phase, .manual, "showManual() → .manual")
    T.ok(store.phase.isTerminal, ".manual терминальна (D40: не in-flight)")
    store.reset()
    T.eq(store.phase, .idle, "reset() → .idle")
}

/// isInFlight / isTerminal по фазам (питает D40-политику terminate).
func test_phaseFlags() {
    T.ok(InstallPhase.downloading(got: 1, total: 2).isInFlight, "downloading in-flight")
    T.ok(InstallPhase.installing.isInFlight, "installing in-flight")
    T.ok(InstallPhase.verifying.isInFlight, "verifying in-flight")
    T.ok(InstallPhase.activating.isInFlight, "activating in-flight")
    T.ok(InstallPhase.precheck.isInFlight, "precheck in-flight")
    T.ok(InstallPhase.success.isTerminal, "success терминальна")
    T.ok(InstallPhase.error(.network).isTerminal, "error терминальна")
    T.ok(InstallPhase.agentActivationFailed.isTerminal, "agentActivationFailed терминальна")
    T.ok(InstallPhase.manual.isTerminal, "manual терминальна")
    T.ok(InstallPhase.idle.isTerminal, "idle терминальна")
}

/// ЖИВАЯ активация через installer.sh (task 4.1): плейсим фикстурный движок в app-owned,
/// гоним installer.sh под защёлкой+тест-меткой+throwaway HOME → плейст перепечён (CALIBRE_MACOS_DIR
/// = app-owned, EBOOK_* производные, WatchPaths[0] = watch), агент реально поднят (bootstrap+kickstart).
/// Боевой агент com.arrivarus.fb2toepub.agent НЕ трогается (метка .test.*). Bootout — в defer.
func test_realInstallerActivation() {
    guard !REPO.isEmpty else { T.ok(false, "нет FB2_REPO_DIR (запуск через раннер)"); return }
    let home = freshHome("activate")
    placeFixtureCalibre(home)
    let watch = "\(home)/watch"
    try? FM.createDirectory(atPath: watch, withIntermediateDirectories: true)
    // СТАБИЛЬНАЯ тест-метка (НЕ pid/uuid): `launchctl enable` внутри installer.sh пишет
    // персистентную override-запись в disabled.<uid>.plist, которую bootout НЕ стирает
    // (нужен root). Стабильная метка → ровно ОДНА инертная запись на все прогоны (мёртвый
    // ярлык больше никогда не грузится), а не по одной за запуск. installer.sh делает
    // bootout ПЕРЕД bootstrap → повторный прогон на той же метке идемпотентен. Боевой
    // com.arrivarus.fb2toepub.agent не затрагивается (метка .test.*, урок 015).
    let label = "com.arrivarus.fb2toepub.test.activation"
    let engine = EngineClient(label: label, home: home, installerPath: "\(REPO)/packaging/installer.sh")
    defer {
        engine.bootout()
        try? FM.removeItem(atPath: engine.plistPath)
    }

    let res = engine.runInstaller(watchDir: watch, extraEnv: [
        "HOME": home,
        "FB2_CALIBRE_TEST_MODE": "1",
        "FB2_CALIBRE_TEST_ROOT": TEST_ROOT,
        "FB2_CALIBRE_DISABLE_SYSTEM": "1",
        "FB2_AGENT_LABEL": label,
    ])
    T.eq(res.status, 0, "installer.sh активация rc=0")
    T.ok(engine.plistExists(), "plist создан под тест-меткой")

    let wantMacos = CalibreTestLatch.canonical("\(CalibreLocator.appOwnedRoot(home: home))/calibre.app/Contents/MacOS")
    let gotMacos = plistRaw("EnvironmentVariables.CALIBRE_MACOS_DIR", engine.plistPath).map { CalibreTestLatch.canonical($0) }
    T.ok(gotMacos == wantMacos, "CALIBRE_MACOS_DIR = app-owned calibre  (got: \(gotMacos ?? "nil"))")
    T.ok(plistRaw("EnvironmentVariables.EBOOK_CONVERT", engine.plistPath)?.hasSuffix("/ebook-convert") == true,
         "EBOOK_CONVERT производный от движка")
    let gotWatch = plistRaw("WatchPaths.0", engine.plistPath).map { CalibreTestLatch.canonical($0) }
    T.ok(gotWatch == CalibreTestLatch.canonical(watch), "WatchPaths[0] = watch dir")

    // H1 (ре-ревью, цикл 2): под защёлкой installer.sh закрепляет в plist HOME + пути
    // state/covers/log, ПРОИЗВОДНЫЕ от throwaway-HOME. Иначе агент, который РЕАЛЬНЫЙ launchd
    // поднимает по этому plist, писал бы боевой state.json / дренировал боевые covers-jobs /
    // писал боевой лог (launchd не пиннит throwaway-HOME). Проверяем: все четыре ключа на
    // месте и указывают в throwaway (равенство с <home>/… = доказательство изоляции).
    let gotHome = plistRaw("EnvironmentVariables.HOME", engine.plistPath).map { CalibreTestLatch.canonical($0) }
    T.ok(gotHome == CalibreTestLatch.canonical(home),
         "plist HOME = throwaway home  (got: \(gotHome ?? "nil"))")
    let gotState = plistRaw("EnvironmentVariables.FB2_STATE_DIR", engine.plistPath).map { CalibreTestLatch.canonical($0) }
    T.ok(gotState == CalibreTestLatch.canonical("\(home)/Library/Application Support/fb2-to-epub/state"),
         "plist FB2_STATE_DIR под throwaway-HOME  (got: \(gotState ?? "nil"))")
    let gotCovers = plistRaw("EnvironmentVariables.FB2_COVERS_DIR", engine.plistPath).map { CalibreTestLatch.canonical($0) }
    T.ok(gotCovers == CalibreTestLatch.canonical("\(home)/Library/Application Support/fb2-to-epub/covers"),
         "plist FB2_COVERS_DIR под throwaway-HOME  (got: \(gotCovers ?? "nil"))")
    let gotLog = plistRaw("EnvironmentVariables.FB2_LOG_FILE", engine.plistPath).map { CalibreTestLatch.canonical($0) }
    T.ok(gotLog == CalibreTestLatch.canonical("\(home)/Library/Logs/fb2-to-epub.log"),
         "plist FB2_LOG_FILE под throwaway-HOME  (got: \(gotLog ?? "nil"))")

    // Агент реально поднят: bootout→bootstrap→enable→kickstart прошли (DoD «kickstart»).
    let st = engine.agentStatus()
    T.ok(st.plistExists, "agentStatus видит plist")
    T.ok(st.isActive, "агент активен после активации (bootstrap ок)")
}

// MARK: - H1 негатив: БЕЗ защёлки боевой plist НЕ несёт тест-ключей (изоляции нет — прод)

/// Красная линия H1: без защёлки (боевая установка) installer.sh НЕ кладёт в plist
/// HOME/FB2_STATE_DIR/FB2_COVERS_DIR/FB2_LOG_FILE — боевой plist остаётся прежним. Изоляция
/// прогона: throwaway HOME + PATH-шайба launchctl (реальный launchd-домен не мутируется),
/// фикстурный движок в app-owned (детект проходит и без защёлки). Латч выключаем ЯВНЫМ
/// FB2_CALIBRE_TEST_MODE=0 — ambient-env раннера несёт =1, а EngineClient только МЕРЖИТ env.
func test_installerPlistNoLeakKeysWithoutLatch() {
    guard !REPO.isEmpty else { T.ok(false, "нет FB2_REPO_DIR (запуск через раннер)"); return }
    let home = freshHome("noleak")
    placeFixtureCalibre(home)   // app-owned → детект пройдёт даже без защёлки
    let watch = "\(home)/watch"
    try? FM.createDirectory(atPath: watch, withIntermediateDirectories: true)

    // PATH-шайба: перехватываем launchctl, чтобы БЕЗ защёлки (метка = боевая) реальный
    // launchd-домен не мутировался. plist при этом пишется в throwaway HOME (безопасно).
    let shim = "\(home)/lshim"
    try? FM.createDirectory(atPath: shim, withIntermediateDirectories: true)
    let stub = "#!/bin/bash\ncase \"${1:-}\" in\n  print|print-disabled) exit 1 ;;\n  *) exit 0 ;;\nesac\n"
    FM.createFile(atPath: "\(shim)/launchctl", contents: stub.data(using: .utf8),
                  attributes: [.posixPermissions: 0o755])

    // Боевая метка по умолчанию, НО home — throwaway: боевой ~/Library/LaunchAgents не тронут.
    let engine = EngineClient(home: home, installerPath: "\(REPO)/packaging/installer.sh")
    defer { try? FM.removeItem(atPath: engine.plistPath) }

    let res = engine.runInstaller(watchDir: watch, extraEnv: [
        "HOME": home,
        "FB2_CALIBRE_TEST_MODE": "0",                       // защёлка ВЫКЛЮЧЕНА (перекрываем ambient =1)
        "FB2_SRC_DIR": "\(REPO)/bin",
        "PATH": "\(shim):/usr/bin:/bin:/usr/sbin:/sbin",     // launchctl → шайба
    ])
    T.eq(res.status, 0, "installer.sh без защёлки rc=0")
    T.ok(engine.plistExists(), "plist создан (throwaway HOME)")

    // ГЛАВНОЕ H1-негатив: НИ ОДНОГО из четырёх тест-ключей (боевой plist не «утёк»).
    T.ok(plistRaw("EnvironmentVariables.HOME", engine.plistPath) == nil,
         "без защёлки: EnvironmentVariables.HOME ОТСУТСТВУЕТ")
    T.ok(plistRaw("EnvironmentVariables.FB2_STATE_DIR", engine.plistPath) == nil,
         "без защёлки: EnvironmentVariables.FB2_STATE_DIR ОТСУТСТВУЕТ")
    T.ok(plistRaw("EnvironmentVariables.FB2_COVERS_DIR", engine.plistPath) == nil,
         "без защёлки: EnvironmentVariables.FB2_COVERS_DIR ОТСУТСТВУЕТ")
    T.ok(plistRaw("EnvironmentVariables.FB2_LOG_FILE", engine.plistPath) == nil,
         "без защёлки: EnvironmentVariables.FB2_LOG_FILE ОТСУТСТВУЕТ")

    // Контроль: обычные ключи на месте — plist валиден, просто без тест-ключей (прод-форма).
    T.ok(plistRaw("EnvironmentVariables.WATCH_DIR", engine.plistPath) != nil,
         "без защёлки: обычный WATCH_DIR на месте (plist валиден)")
    T.ok(plistRaw("EnvironmentVariables.CALIBRE_MACOS_DIR", engine.plistPath) != nil,
         "без защёлки: обычный CALIBRE_MACOS_DIR на месте")
}

// MARK: - S1 (хвост 1): cleanupLeftovers восстанавливает движок из .old при двойной аварии

/// Состояние «после двойной аварии»: calibre.app ОТСУТСТВУЕТ, а calibre.app.old — валиден
/// (3 CLI). cleanupLeftovers обязан ВЕРНУТЬ .old → calibre.app (единственный рабочий движок),
/// а не снести его. Штатные случаи (calibre.app на месте) закрыты test_cleanupLeftovers.
func test_cleanupLeftoversRestoresFromOld() {
    let home = freshHome("restore-old")
    let root = CalibreLocator.appOwnedRoot(home: home)
    let oldMacos = "\(root)/calibre.app.old/Contents/MacOS"
    try? FM.createDirectory(atPath: oldMacos, withIntermediateDirectories: true)
    for cli in CalibreLocation.requiredCLIs {
        FM.createFile(atPath: "\(oldMacos)/\(cli)", contents: Data("#!/bin/bash\nexit 0\n".utf8),
                      attributes: [.posixPermissions: 0o755])
    }
    // Сопутствующий мусор двойной аварии (должен быть снесён как обычно).
    try? FM.createDirectory(atPath: "\(root)/calibre.app.installing/Contents/MacOS", withIntermediateDirectories: true)

    T.ok(!exists("\(root)/calibre.app"), "предусловие: calibre.app отсутствует")
    T.ok(CalibreLocator.isValid(macosDir: oldMacos), "предусловие: .old валиден (3 CLI)")

    CalibreInstaller.cleanupLeftovers(home: home)

    T.ok(exists("\(root)/calibre.app"), "calibre.app ВОССТАНОВЛЕН из .old")
    T.ok(CalibreLocator.isValid(macosDir: "\(root)/calibre.app/Contents/MacOS"),
         "восстановленный движок валиден (3 CLI на месте)")
    T.ok(!exists("\(root)/calibre.app.old"), ".old убран после восстановления (перемещён)")
    T.ok(!exists("\(root)/calibre.app.installing"), "сопутствующий staging снесён")
    T.eq(CalibreLocator.resolve(home: home, env: ENV)?.kind, .appOwned,
         "после восстановления локатор видит app-owned движок")
}

// MARK: - Прогон

print("TAP version 13")
print("# CalibreInstaller — интеграционные тесты конвейера (CAL-3) + сшивка (CAL-4)")
guard !SERVER.isEmpty, !TEST_ROOT.isEmpty else {
    print("Bail out! нет FB2_TEST_SERVER / FB2_CALIBRE_TEST_ROOT (запускать через run-calibre-install-tests.sh)")
    exit(1)
}

T.run("happy-path + идемпотентность", test_happy)
T.run("негатив: битый sha", test_badSHA)
T.run("негатив: DMG без calibre.app", test_noApp)
T.run("негатив: verify-fail (rc≠0)", test_verifyFail)
T.run("негатив: нет места", test_noSpace)
T.run("негатив: отмена на середине", test_cancel)
T.run("негатив: LSMinimumSystemVersion выше ОС", test_highOS)
T.run("S1: провал второго rename свопа → откат .old", test_swapSecondRenameRollback)
T.run("защёлка выключена → env игнорируются", test_latchOff)
T.run("защёлка: install-root вне TEST_ROOT", test_latchOutsideRoot)
T.run("B1: полузведённая защёлка → громкий отказ", test_halfCockedLatch)
T.run("OS-гейт (D42) → manual", test_osGate)
T.run("стартовая зачистка остатков", test_cleanupLeftovers)
T.run("S1: cleanupLeftovers восстанавливает движок из .old", test_cleanupLeftoversRestoresFromOld)
T.run("InstallStore re-entry guard", test_installStoreGuard)

// CAL-4: сшивка — оркестрация InstallStore (конвейер → оживление агента) + живая активация.
T.run("CAL-4: конвейер → активация success", test_chainSuccess)
T.run("CAL-4: движок есть, агент не встал → agentActivationFailed", test_chainAgentFail)
T.run("CAL-4: activateOnly (повтор без скачивания)", test_activateOnly)
T.run("CAL-4: showManual / reset", test_showManualReset)
T.run("CAL-4: флаги фаз isInFlight/isTerminal (D40)", test_phaseFlags)
T.run("CAL-4: живая активация agent'а через installer.sh", test_realInstallerActivation)
T.run("H1 негатив: без защёлки боевой plist без тест-ключей", test_installerPlistNoLeakKeysWithoutLatch)

print("")
print("1..\(T.passed + T.failed)")
print("# passed: \(T.passed)")
print("# failed: \(T.failed)")
exit(T.failed == 0 ? 0 : 1)
