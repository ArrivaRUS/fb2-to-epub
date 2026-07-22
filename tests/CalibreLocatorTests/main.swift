// main.swift — юниты контракта детекта Calibre (CAL-1, app/CalibreLocator.swift).
//
// ЧТО ПОД ТЕСТОМ
// --------------
//   • порядок кандидатов: app-owned → /Applications → ~/Applications;
//   • валидность = исполняемы ВСЕ ТРИ CLI (частичный Calibre = «движка нет»);
//   • тест-защёлка (урок 015): FB2_CALIBRE_TEST_ROOT / FB2_CALIBRE_DISABLE_SYSTEM
//     работают ТОЛЬКО при FB2_CALIBRE_TEST_MODE=1, а мутирующие оверрайды —
//     ещё и при install-root ВНУТРИ канонизированного TEST_ROOT.
//
// ИЗОЛЯЦИЯ
// --------
// Все деревья — фикстуры в `mktemp -d` со СТАБАМИ вместо CLI (на этой машине
// Calibre не установлен вообще, и тесты на него не завязаны). Реальный
// /Applications никогда не нужен: «системный» кандидат подаётся синтетическим
// списком через resolve(candidates:) — ту же функцию, которой пользуется
// продакшен-resolve. Env не трогаем: во все вызовы env передаётся явным словарём.
// Тесты НИЧЕГО не пишут вне своей временной папки и не запускают процессов.

import Foundation

// MARK: - Крошечный TAP-раннер (как в ClearHistoryTests — без XCTest)

final class T {
    static var passed = 0
    static var failed = 0
    static var current = "<none>"

    static func ok(_ cond: @autoclosure () -> Bool, _ msg: String) {
        if cond() {
            passed += 1
            print("  ok   - \(msg)")
        } else {
            failed += 1
            print("  FAIL - \(msg)   [in: \(current)]")
        }
    }

    static func eq<V: Equatable>(_ a: V, _ b: V, _ msg: String) {
        ok(a == b, "\(msg)  (got: \(a), want: \(b))")
    }

    static func run(_ name: String, _ body: () throws -> Void) {
        current = name
        print("# \(name)")
        do { try body() } catch {
            failed += 1
            print("  FAIL - threw: \(error)   [in: \(name)]")
        }
    }
}

// MARK: - Фикстуры

enum Fx {
    static let fm = FileManager.default

    /// Временный корень теста. Канонизирован, чтобы сравнения путей были точными
    /// (/var/folders → /private/var/folders).
    static func tempRoot(_ tag: String) -> String {
        let base = NSTemporaryDirectory() + "fb2-callocator-\(tag)-\(UUID().uuidString.prefix(8))"
        try? fm.createDirectory(atPath: base, withIntermediateDirectories: true)
        return CalibreTestLatch.canonical(base)
    }

    /// Собрать calibre.app с указанными CLI-стабами. Возвращает путь к бандлу.
    /// Стаб — исполняемый шелл-скрипт, отвечающий на `--version` (как настоящий
    /// CLI), но локатор его НЕ запускает: детект чисто файловый (3× stat).
    @discardableResult
    static func makeCalibre(at appPath: String,
                            clis: [String] = CalibreLocation.requiredCLIs) -> String {
        let macos = "\(appPath)/Contents/MacOS"
        try? fm.createDirectory(atPath: macos, withIntermediateDirectories: true)
        for cli in clis {
            let p = "\(macos)/\(cli)"
            try? "#!/bin/bash\necho \"\(cli) (calibre 9.9.9)\"\n".write(toFile: p,
                                                                        atomically: true,
                                                                        encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p)
        }
        return appPath
    }

    /// Путь, по которому локатор ждёт нашу (app-owned) установку внутри `home`.
    static func appOwnedApp(home: String) -> String {
        "\(CalibreLocator.appOwnedRoot(home: home))/calibre.app"
    }

    /// Пустой каталог (используется как «дерева нет»).
    static func makeDir(_ path: String) -> String {
        try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    static let latchOn = [CalibreTestLatch.testModeKey: "1"]
}

// MARK: - Группа A: пять фикстурных деревьев

// A1. Только app-owned: движок в нашей папке, системных кандидатов нет.
func test_A1_onlyAppOwned() {
    let root = Fx.tempRoot("a1")
    let home = Fx.makeDir("\(root)/home")
    Fx.makeCalibre(at: Fx.appOwnedApp(home: home))

    // Системные кандидаты выключены защёлкой → остаётся только app-owned.
    let env = [CalibreTestLatch.testModeKey: "1",
               CalibreTestLatch.testRootKey: root,
               CalibreTestLatch.disableSystemKey: "1"]
    let loc = CalibreLocator.resolve(home: home, env: env)

    T.ok(loc != nil, "движок найден")
    T.eq(loc?.kind, .appOwned, "kind = appOwned")
    T.eq(loc?.macosDir, "\(Fx.appOwnedApp(home: home))/Contents/MacOS", "macosDir указывает в нашу папку")
    T.eq(loc?.ebookConvert, "\(Fx.appOwnedApp(home: home))/Contents/MacOS/ebook-convert", "ebookConvert выведен из macosDir")
    T.eq(loc?.ebookMeta, "\(Fx.appOwnedApp(home: home))/Contents/MacOS/ebook-meta", "ebookMeta выведен из macosDir")
    T.eq(loc?.ebookPolish, "\(Fx.appOwnedApp(home: home))/Contents/MacOS/ebook-polish", "ebookPolish выведен из macosDir")
}

// A2. Только системный: наша папка пуста, «/Applications» (синтетический
// кандидат — реальный каталог трогать не надо) содержит полную установку.
func test_A2_onlySystem() {
    let root = Fx.tempRoot("a2")
    let home = Fx.makeDir("\(root)/home")
    let system = Fx.makeCalibre(at: "\(root)/Applications/calibre.app")

    let list = [
        CalibreLocator.Candidate(appPath: Fx.appOwnedApp(home: home), kind: .appOwned),
        CalibreLocator.Candidate(appPath: system, kind: .system),
    ]
    let loc = CalibreLocator.resolve(candidates: list)

    T.eq(loc?.kind, .system, "пустая app-owned пропущена → взят системный")
    T.eq(loc?.macosDir, "\(system)/Contents/MacOS", "macosDir системного кандидата")
}

// A3. Оба сразу: побеждает app-owned (порядок контракта, а не «что новее»).
func test_A3_bothAppOwnedWins() {
    let root = Fx.tempRoot("a3")
    let home = Fx.makeDir("\(root)/home")
    Fx.makeCalibre(at: Fx.appOwnedApp(home: home))
    let system = Fx.makeCalibre(at: "\(root)/Applications/calibre.app")

    let list = [
        CalibreLocator.Candidate(appPath: Fx.appOwnedApp(home: home), kind: .appOwned),
        CalibreLocator.Candidate(appPath: system, kind: .system),
    ]
    let loc = CalibreLocator.resolve(candidates: list)

    T.eq(loc?.kind, .appOwned, "при обоих валидных выигрывает app-owned")
}

// A4. Частичная установка (нет ebook-polish) — это «движка нет», а не «есть».
// Именно она ломала обложки на этапе ebook-polish уже ПОСЛЕ старта конвертации.
func test_A4_partialWithoutPolish() {
    let root = Fx.tempRoot("a4")
    let home = Fx.makeDir("\(root)/home")
    Fx.makeCalibre(at: Fx.appOwnedApp(home: home), clis: ["ebook-convert", "ebook-meta"])

    let env = [CalibreTestLatch.testModeKey: "1",
               CalibreTestLatch.testRootKey: root,
               CalibreTestLatch.disableSystemKey: "1"]
    T.ok(CalibreLocator.resolve(home: home, env: env) == nil, "частичный Calibre → движка нет")

    // И симметрично: без ebook-meta тоже «нет».
    let root2 = Fx.tempRoot("a4b")
    let home2 = Fx.makeDir("\(root2)/home")
    Fx.makeCalibre(at: Fx.appOwnedApp(home: home2), clis: ["ebook-convert", "ebook-polish"])
    let env2 = [CalibreTestLatch.testModeKey: "1",
                CalibreTestLatch.testRootKey: root2,
                CalibreTestLatch.disableSystemKey: "1"]
    T.ok(CalibreLocator.resolve(home: home2, env: env2) == nil, "без ebook-meta → движка нет")
}

// A5. Пусто: ни одного кандидата с файлами.
func test_A5_empty() {
    let root = Fx.tempRoot("a5")
    let home = Fx.makeDir("\(root)/home")

    let env = [CalibreTestLatch.testModeKey: "1",
               CalibreTestLatch.testRootKey: root,
               CalibreTestLatch.disableSystemKey: "1"]
    T.ok(CalibreLocator.resolve(home: home, env: env) == nil, "пустое дерево → nil")
}

// MARK: - Группа B: что считается валидным CLI

func test_B1_validityRules() {
    let root = Fx.tempRoot("b1")
    let macos = Fx.makeDir("\(root)/calibre.app/Contents/MacOS")

    // Каталог с битом +x вместо файла — НЕ CLI.
    _ = Fx.makeDir("\(macos)/ebook-convert")
    T.ok(!CalibreLocator.isValid(macosDir: macos), "каталог с +x не считается исполняемым CLI")

    // Файл без +x — тоже нет.
    let root2 = Fx.tempRoot("b2")
    let macos2 = Fx.makeDir("\(root2)/calibre.app/Contents/MacOS")
    for cli in CalibreLocation.requiredCLIs {
        try? "x".write(toFile: "\(macos2)/\(cli)", atomically: true, encoding: .utf8)
        try? Fx.fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: "\(macos2)/\(cli)")
    }
    T.ok(!CalibreLocator.isValid(macosDir: macos2), "файл без бита +x не считается CLI")

    // Все три исполняемы — валидно.
    let root3 = Fx.tempRoot("b3")
    let app3 = Fx.makeCalibre(at: "\(root3)/calibre.app")
    T.ok(CalibreLocator.isValid(macosDir: "\(app3)/Contents/MacOS"), "все три +x → валидно")
}

// MARK: - Группа C: порядок кандидатов и тест-защёлка

// C1. Без защёлки — ровно три кандидата контракта, в порядке контракта.
func test_C1_contractOrderNoLatch() {
    let home = "/tmp/fake-home-c1"
    let c = CalibreLocator.candidates(home: home, env: [:])

    T.eq(c.count, 3, "три кандидата без защёлки")
    T.eq(c.map { $0.kind }, [.appOwned, .system, .userApplications], "порядок: app-owned → system → ~/Applications")
    T.eq(c[0].appPath, "\(home)/Library/Application Support/fb2-to-epub/calibre.app", "1-й — наша папка")
    T.eq(c[1].appPath, "/Applications/calibre.app", "2-й — /Applications")
    T.eq(c[2].appPath, "\(home)/Applications/calibre.app", "3-й — ~/Applications")
}

// C2. Защёлка взведена: TEST_ROOT-кандидат ВСТАВЛЯЕТСЯ первым, app-owned остаётся.
func test_C2_latchPrependsTestRoot() {
    let root = Fx.tempRoot("c2")
    let home = "\(root)/home"
    let env = [CalibreTestLatch.testModeKey: "1", CalibreTestLatch.testRootKey: root]
    let c = CalibreLocator.candidates(home: home, env: env)

    T.eq(c.count, 4, "под защёлкой кандидатов четыре")
    T.eq(c[0].kind, .testRoot, "первый — TEST_ROOT")
    T.eq(c[0].appPath, "\(root)/calibre.app", "путь TEST_ROOT-кандидата")
    T.eq(c[1].kind, .appOwned, "app-owned НЕ вытеснен, он второй")
}

// C3. DISABLE_SYSTEM под защёлкой убирает кандидатов 2–3.
func test_C3_latchDisablesSystem() {
    let root = Fx.tempRoot("c3")
    let home = "\(root)/home"
    let env = [CalibreTestLatch.testModeKey: "1",
               CalibreTestLatch.testRootKey: root,
               CalibreTestLatch.disableSystemKey: "1"]
    let c = CalibreLocator.candidates(home: home, env: env)

    T.eq(c.map { $0.kind }, [.testRoot, .appOwned], "остались только TEST_ROOT и app-owned")
    T.ok(!c.contains { $0.appPath == "/Applications/calibre.app" }, "/Applications выключен")
}

// C4. ЗАЩЁЛКИ НЕТ → оба env молча игнорируются (главный урок 015).
func test_C4_noLatchIgnoresEnv() {
    let root = Fx.tempRoot("c4")
    let home = "\(root)/home"

    // TEST_MODE не выставлен, хотя ROOT и DISABLE_SYSTEM есть.
    let env = [CalibreTestLatch.testRootKey: root,
               CalibreTestLatch.disableSystemKey: "1"]
    let c = CalibreLocator.candidates(home: home, env: env)

    T.eq(c.map { $0.kind }, [.appOwned, .system, .userApplications], "без TEST_MODE — обычный контракт")
    T.ok(!c.contains { $0.kind == .testRoot }, "TEST_ROOT-кандидат не подставлен")
    T.ok(c.contains { $0.appPath == "/Applications/calibre.app" }, "DISABLE_SYSTEM проигнорирован")
    T.ok(CalibreTestLatch.testRoot(env: env) == nil, "защёлка не взведена")
}

// C5. TEST_MODE=1, но TEST_ROOT пустой/несуществующий → защёлки НЕТ.
func test_C5_latchNeedsRealRoot() {
    T.ok(CalibreTestLatch.testRoot(env: Fx.latchOn) == nil, "TEST_MODE без ROOT → защёлки нет")

    var env = Fx.latchOn
    env[CalibreTestLatch.testRootKey] = ""
    T.ok(CalibreTestLatch.testRoot(env: env) == nil, "пустой ROOT → защёлки нет")

    env[CalibreTestLatch.testRootKey] = "/nonexistent/fb2-\(UUID().uuidString)"
    T.ok(CalibreTestLatch.testRoot(env: env) == nil, "несуществующий ROOT → защёлки нет")

    // Файл вместо каталога — тоже не годится.
    let root = Fx.tempRoot("c5")
    let file = "\(root)/not-a-dir"
    try? "x".write(toFile: file, atomically: true, encoding: .utf8)
    env[CalibreTestLatch.testRootKey] = file
    T.ok(CalibreTestLatch.testRoot(env: env) == nil, "ROOT-файл (не каталог) → защёлки нет")
}

// C6. TEST_ROOT=/ → защёлки нет (внутри «/» лежит вообще всё, боевые пути включительно).
func test_C6_latchRejectsRootSlash() {
    var env = Fx.latchOn
    env[CalibreTestLatch.testRootKey] = "/"
    T.ok(CalibreTestLatch.testRoot(env: env) == nil, "TEST_ROOT=/ → защёлки нет")
}

// C7. TEST_ROOT, СОДЕРЖАЩИЙ настоящий домашний каталог пользователя (getpwuid, НЕ $HOME) →
// защёлки нет: иначе мутирующие оверрайды навелись бы на боевые пути. Берём сам домашний
// каталог как TEST_ROOT (он «содержит» себя). Проверка чистая — на диск ничего не пишем.
func test_C7_latchRejectsRootContainingHome() {
    guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else {
        T.ok(false, "не смог прочитать passwd-home"); return
    }
    let realHome = String(cString: dir)
    var env = Fx.latchOn
    env[CalibreTestLatch.testRootKey] = realHome
    T.ok(CalibreTestLatch.testRoot(env: env) == nil,
         "TEST_ROOT = домашний каталог пользователя → защёлки нет (слишком широкий TEST_ROOT отвергнут)")

    // Контроль: обычный mktemp-TEST_ROOT (НЕ содержит домашний каталог) по-прежнему взводит защёлку.
    let okRoot = Fx.tempRoot("c7ok")
    var env2 = Fx.latchOn
    env2[CalibreTestLatch.testRootKey] = okRoot
    T.eq(CalibreTestLatch.testRoot(env: env2), okRoot, "нормальный TEST_ROOT по-прежнему взводит защёлку")
}

// MARK: - Группа D: мутирующая защёлка (install-root внутри TEST_ROOT)

func test_D1_allowsMutation() {
    let root = Fx.tempRoot("d1")
    let env = [CalibreTestLatch.testModeKey: "1", CalibreTestLatch.testRootKey: root]

    T.ok(CalibreTestLatch.allowsMutation(installRoot: "\(root)/home/Library/Application Support/fb2-to-epub", env: env),
         "install-root внутри TEST_ROOT → мутирующие оверрайды разрешены")
    T.ok(CalibreTestLatch.allowsMutation(installRoot: root, env: env),
         "сам TEST_ROOT считается внутри")
    T.ok(!CalibreTestLatch.allowsMutation(installRoot: "\(NSHomeDirectory())/Library/Application Support/fb2-to-epub", env: env),
         "БОЕВОЙ install-root вне TEST_ROOT → мутирующие оверрайды ЗАПРЕЩЕНЫ")
    T.ok(!CalibreTestLatch.allowsMutation(installRoot: "\(root)-evil/x", env: env),
         "сосед с общим префиксом (<root>-evil) не считается внутри")
    T.ok(!CalibreTestLatch.allowsMutation(installRoot: "\(root)/home", env: [:]),
         "без защёлки мутирующие оверрайды запрещены всегда")
}

// D2. Канонизация: симлинк-путь и реальный путь дают один вердикт.
func test_D2_canonicalization() {
    let root = Fx.tempRoot("d2")   // уже канонизирован (/private/var/...)
    let env = [CalibreTestLatch.testModeKey: "1", CalibreTestLatch.testRootKey: root]

    T.eq(CalibreTestLatch.testRoot(env: env), root, "канонизированный ROOT возвращается как есть")
    T.eq(CalibreTestLatch.canonical("/tmp"), "/private/tmp", "/tmp развёрнут в /private/tmp")
    T.eq(CalibreTestLatch.canonical("/private/tmp/"), "/private/tmp", "хвостовой слэш срезан")
    T.ok(CalibreTestLatch.isInside(path: "/a/b/c", root: "/a/b"), "вложенный путь внутри")
    T.ok(!CalibreTestLatch.isInside(path: "/a/bb", root: "/a/b"), "граница сегмента соблюдена")
}

// MARK: - Группа E: резолвер домашней директории (EngineHome, П1)

// Опровергнутое допущение plans.md: NSHomeDirectory() ИГНОРИРУЕТ $HOME у напрямую
// запущенного бинаря (Darwin 25.5) → харнесс не мог изолировать приложение. Резолвер:
// под тест-защёлкой (та же граница, что CalibreTestLatch) берёт env HOME, иначе —
// NSHomeDirectory() (прод байт-в-байт). Env во все вызовы передаём явным словарём.

// E1. Защёлка взведена + env HOME, чей install-root ВНУТРИ TEST_ROOT → env HOME.
func test_E1_latchedReturnsEnvHome() {
    let root = Fx.tempRoot("e1")
    let home = Fx.makeDir("\(root)/home")
    let env = [CalibreTestLatch.testModeKey: "1",
               CalibreTestLatch.testRootKey: root,
               "HOME": home]
    T.eq(EngineHome.resolve(env: env), home,
         "латч + env HOME (install-root внутри TEST_ROOT) → env HOME")
}

// E2. env HOME указывает ВНЕ TEST_ROOT → прод-путь (NSHomeDirectory).
func test_E2_homeOutsideRootFallsBack() {
    let root = Fx.tempRoot("e2")
    _ = Fx.makeDir("\(root)/home")
    let outside = Fx.tempRoot("e2-outside")   // отдельное дерево, вне TEST_ROOT
    let env = [CalibreTestLatch.testModeKey: "1",
               CalibreTestLatch.testRootKey: root,
               "HOME": outside]
    T.eq(EngineHome.resolve(env: env), NSHomeDirectory(),
         "env HOME вне TEST_ROOT → NSHomeDirectory (прод)")
}

// E3. TEST_MODE есть, а HOME не задан → прод-путь.
func test_E3_testModeWithoutHomeFallsBack() {
    let root = Fx.tempRoot("e3")
    let env = [CalibreTestLatch.testModeKey: "1",
               CalibreTestLatch.testRootKey: root]   // без HOME
    T.eq(EngineHome.resolve(env: env), NSHomeDirectory(),
         "TEST_MODE без HOME → NSHomeDirectory (прод)")
}

// E4. КРАСНАЯ ЛИНИЯ (негатив): без FB2_CALIBRE_TEST_MODE резолвер ВСЕГДА даёт
// NSHomeDirectory, даже если HOME + TEST_ROOT заданы — боевой env на машине человека
// не должен ничего менять (прод байт-в-байт).
func test_E4_noTestModeIsProd() {
    let root = Fx.tempRoot("e4")
    let home = Fx.makeDir("\(root)/home")
    let env = ["HOME": home,
               CalibreTestLatch.testRootKey: root]   // FB2_CALIBRE_TEST_MODE НЕ задан
    T.eq(EngineHome.resolve(env: env), NSHomeDirectory(),
         "нет TEST_MODE → NSHomeDirectory, env HOME игнорируется (прод)")
}

// MARK: - Прогон

print("# --- CAL-1: контракт детекта (пять фикстурных деревьев) ---")
T.run("A1 только app-owned", test_A1_onlyAppOwned)
T.run("A2 только системный", test_A2_onlySystem)
T.run("A3 оба → выигрывает app-owned", test_A3_bothAppOwnedWins)
T.run("A4 частичный (без polish/meta) → движка нет", test_A4_partialWithoutPolish)
T.run("A5 пусто → nil", test_A5_empty)

print("# --- CAL-1: что считается исполняемым CLI ---")
T.run("B1 правила валидности", test_B1_validityRules)

print("# --- CAL-1: порядок кандидатов и тест-защёлка (урок 015) ---")
T.run("C1 порядок контракта без защёлки", test_C1_contractOrderNoLatch)
T.run("C2 защёлка вставляет TEST_ROOT первым", test_C2_latchPrependsTestRoot)
T.run("C3 DISABLE_SYSTEM убирает кандидатов 2–3", test_C3_latchDisablesSystem)
T.run("C4 без TEST_MODE env игнорируются", test_C4_noLatchIgnoresEnv)
T.run("C5 защёлке нужен настоящий TEST_ROOT", test_C5_latchNeedsRealRoot)
T.run("C6 TEST_ROOT=/ отвергнут", test_C6_latchRejectsRootSlash)
T.run("C7 TEST_ROOT, содержащий домашний каталог, отвергнут", test_C7_latchRejectsRootContainingHome)

print("# --- CAL-1: мутирующая защёлка (install-root внутри TEST_ROOT) ---")
T.run("D1 allowsMutation", test_D1_allowsMutation)
T.run("D2 канонизация и границы", test_D2_canonicalization)

print("# --- П1: резолвер домашней директории (EngineHome) ---")
T.run("E1 латч → env HOME", test_E1_latchedReturnsEnvHome)
T.run("E2 HOME вне TEST_ROOT → NSHomeDirectory", test_E2_homeOutsideRootFallsBack)
T.run("E3 TEST_MODE без HOME → NSHomeDirectory", test_E3_testModeWithoutHomeFallsBack)
T.run("E4 нет TEST_MODE → NSHomeDirectory (прод)", test_E4_noTestModeIsProd)

print("")
print("1..\(T.passed + T.failed)")
print("# passed: \(T.passed)")
print("# failed: \(T.failed)")
exit(T.failed == 0 ? 0 : 1)
