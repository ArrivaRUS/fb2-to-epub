// main.swift — тонкий драйвер РЕАЛЬНОГО конвейера CalibreInstaller для живого e2e (CAL-5, task 5.1).
//
// ЗАЧЕМ ОТДЕЛЬНЫЙ БИНАРЬ
// ---------------------
// Скачивание/установка движка обязаны идти ЧЕРЕЗ НАШ конвейер `CalibreInstaller`
// (урок 016 + красная линия брифа: «не curl-ом мимо кода»). Конвейер — Swift, поэтому
// живой e2e-скрипт (bash) компилирует и запускает этот крошечный драйвер: он строит
// `CalibreInstaller.Config` из окружения и гоняет `runSync` до терминальной фазы.
//
// РЕЖИМЫ (задаёт окружением сам run-calibre-live-e2e.sh):
//   • ЖИВОЙ (RUN_LIVE=1): в env НЕТ тест-защёлки → `mutationAllowed=false` →
//     прод-URL https://calibre-ebook.com/dist/osx, НАСТОЯЩИЙ codesign --verify, SHA-512 с сайта.
//   • СУХОЙ (dry-run, моя валидация): в env защёлка (FB2_CALIBRE_TEST_MODE=1 + TEST_ROOT,
//     содержащий install-root) + FB2_CALIBRE_DMG_URL/SHA512_URL на localhost-фикстуру +
//     FB2_CALIBRE_SKIP_CODESIGN=1 → тот же конвейер, но без сети и без 330 МБ.
// Драйвер про режим НЕ знает — всё решает защёлка внутри CalibreInstaller (инвариант 6).
//
// ВХОД (env):  E2E_HOME (throwaway HOME, обязателен) · E2E_MIN_DL_BYTES / E2E_DISK_BYTES
//              (опц. пороги — dry-run ставит маленькие; живой не трогает → реальные дефолты).
// ВЫХОД:       stdout построчно «E2E-phase: …» (наблюдаемость) + «E2E-terminal: …»; rc 0 = success.
//
// Foundation-only, компилируется рядом с CalibreLocator.swift + CalibreInstaller.swift
// ровно как tests/CalibreInstallTests (xcrun swiftc, whole-module). Прод-код НЕ меняется.

import Foundation

// stdout без буферизации — bash-раннер видит прогресс скачивания вживую (иначе пайп копит).
setvbuf(stdout, nil, _IONBF, 0)

let env = ProcessInfo.processInfo.environment

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(("run-calibre-live-e2e[driver]: " + msg + "\n").data(using: .utf8)!)
    exit(2)
}

guard let home = env["E2E_HOME"], !home.isEmpty else {
    die("нет E2E_HOME (запуск через run-calibre-live-e2e.sh)")
}

var config = CalibreInstaller.Config(home: home, env: env)
// Пороги: dry-run передаёт крошечные (фикстура ~5 МБ), живой — не задаёт (реальные 1,5 ГБ / 50 МБ).
if let s = env["E2E_MIN_DL_BYTES"], let v = Int64(s) { config.minDownloadBytes = v }
if let s = env["E2E_DISK_BYTES"], let v = Int64(s) { config.diskThresholdBytes = v }

let installer = CalibreInstaller(config: config)

print("E2E: appOwnedRoot=\(installer.appOwnedRoot)")
print("E2E: installedApp=\(installer.installedApp)")
print("E2E: mutationAllowed=\(installer.mutationAllowed)")     // живой=false (прод-URL+настоящий codesign)
print("E2E: autoInstallSupported=\(installer.autoInstallSupported)")
let (dmgURL, isOverride) = installer.effectiveDMGURL()
print("E2E: dmgURL=\(dmgURL.absoluteString) override=\(isOverride)")
print("E2E: skipCodesign=\(installer.skipCodesign)")           // живой=false (настоящий codesign --verify)

// Прогресс печатаем на смену «ведра» (каждые ~25 МБ) — иначе тысячи строк на 330 МБ.
var lastKey = ""
let terminal = installer.runSync { p in
    let key: String
    switch p {
    case .downloading(let got, _):
        key = "downloading:\(got / (25 * 1024 * 1024))"
    default:
        key = "\(p)"
    }
    guard key != lastKey else { return }
    lastKey = key
    if case .downloading(let got, let total) = p {
        print("E2E-phase: downloading \(got / (1024 * 1024))/\(total / (1024 * 1024)) MB")
    } else {
        print("E2E-phase: \(p)")
    }
}

print("E2E-terminal: \(terminal)")
if terminal == .success {
    print("E2E: OK — движок уложен в \(installer.installedApp)")
    exit(0)
}
exit(1)
