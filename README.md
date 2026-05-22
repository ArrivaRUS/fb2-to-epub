# fb2-to-epub

Автоматическая конвертация **FB2 → EPUB** на macOS. Кидаешь файлы или папки в отслеживаемую папку — рядом появляются готовые `.epub`. Без UI, без ручных запусков.

## Что делает

В папку `~/Desktop/fb2-to-epub` можно бросать:

- **Отдельный файл** `*.fb2` или `*.fb2.zip` → рядом появится файл с тем же именем и расширением `.epub`.
- **Папку с книгами** (любая вложенность) → рядом создаётся папка-зеркало с суффиксом `-epub`, в которой воссоздана структура подкаталогов и лежат сконвертированные `.epub`.

Исходники не трогаются. Повторные срабатывания идемпотентны — уже сконвертированное пропускается (epub считается актуальным, если он новее источника).

## Как работает

- macOS `launchd` отслеживает папку через `WatchPaths`.
- При появлении новых файлов запускается [`bin/fb2-to-epub-watcher.sh`](bin/fb2-to-epub-watcher.sh).
- Конвертацию выполняет [Calibre](https://calibre-ebook.com) — CLI `ebook-convert`.
- `ThrottleInterval=5s` сглаживает пакетное копирование, lock-каталог в `/tmp` сериализует параллельные запуски.

## Требования

- macOS
- [Calibre](https://calibre-ebook.com) — нужен бинарь `/Applications/calibre.app/Contents/MacOS/ebook-convert`

## Установка

```sh
# 1. Calibre (если ещё нет)
brew install --cask calibre

# 2. Клонировать и установить
git clone https://github.com/ArrivaRUS/fb2-to-epub.git
cd fb2-to-epub
./install.sh
```

После установки кидай `.fb2` / `.fb2.zip` или папки с ними в `~/Desktop/fb2-to-epub`.

## Управление

| Действие | Команда |
| --- | --- |
| Логи в реальном времени | `tail -f ~/Library/Logs/fb2-to-epub.log` |
| Остановить агент | `launchctl unload ~/Library/LaunchAgents/com.user.fb2-to-epub.plist` |
| Запустить агент | `launchctl load -w ~/Library/LaunchAgents/com.user.fb2-to-epub.plist` |
| Прогон вручную | `launchctl kickstart -k gui/$(id -u)/com.user.fb2-to-epub` |
| Удалить | `./uninstall.sh` |

## Структура проекта

```
.
├── bin/fb2-to-epub-watcher.sh                  — основной скрипт
├── launchd/com.user.fb2-to-epub.plist.template — шаблон LaunchAgent (HOME подставляется install.sh)
├── install.sh                                  — установка + загрузка агента
└── uninstall.sh                                — снятие агента
```

## Лицензия

[MIT](LICENSE)
