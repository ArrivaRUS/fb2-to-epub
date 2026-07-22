// main.swift — Swift-зонд для parity-теста контракта детекта (CAL-1).
//
// Печатает результат CalibreLocator.resolve() в ТОЧНО ТОМ ЖЕ формате, в каком
// его печатает bash-близнец `packaging/installer.sh` под FB2_CALIBRE_DETECT_ONLY=1:
//
//     CALIBRE_MACOS_DIR=<...>/Contents/MacOS
//     EBOOK_CONVERT=<...>/ebook-convert
//     EBOOK_META=<...>/ebook-meta
//     EBOOK_POLISH=<...>/ebook-polish
//
// либо единственную строку `CALIBRE_MACOS_DIR=NONE`, если движка нет.
//
// Зонд НИЧЕГО не пишет и ничего не запускает — только stat по кандидатам.
// `home` берём из HOME окружения (а не NSHomeDirectory), чтобы раннер мог
// подставить throwaway-дерево и обе реализации гарантированно смотрели в одно место.

import Foundation

let env = ProcessInfo.processInfo.environment
let home = env["HOME"] ?? NSHomeDirectory()

guard let loc = CalibreLocator.resolve(home: home, env: env) else {
    print("CALIBRE_MACOS_DIR=NONE")
    exit(0)
}

print("CALIBRE_MACOS_DIR=\(loc.macosDir)")
print("EBOOK_CONVERT=\(loc.ebookConvert)")
print("EBOOK_META=\(loc.ebookMeta)")
print("EBOOK_POLISH=\(loc.ebookPolish)")
