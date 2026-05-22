# fb2-to-epub

Автоматическая конвертация **FB2 → EPUB** на macOS. Кидаешь файлы или папки в отслеживаемую папку — рядом появляются готовые `.epub`. Без UI, без ручных запусков.

## Что делает

В папку `~/Desktop/fb2-to-epub` можно бросать:

- **Отдельный файл** `*.fb2` или `*.fb2.zip` → рядом появится файл с тем же именем и расширением `.epub`.
- **Папку с книгами** (любая вложенность) → рядом создаётся папка-зеркало с суффиксом `-epub`, в которой воссоздана структура подкаталогов и лежат сконвертированные `.epub`.

Исходники не трогаются. Повторные срабатывания идемпотентны — уже сконвертированное пропускается (epub считается актуальным, если он новее источника).

### Обработка обложек

- Если в FB2 есть встроенная обложка — Calibre использует её.
- Если обложки нет — скрипт ищет её онлайн по title + author. Источники в порядке приоритета:
  1. [Open Library](https://openlibrary.org) — основной (стабильный, без ключей, нормально работает с русскими названиями)
  2. [Google Books](https://developers.google.com/books) — fallback (шире каталог, но публичный endpoint жёстко ограничен по IP)

  Найденная обложка скачивается и подсовывается Calibre через `--cover`.
- Если интернет недоступен или ничего не нашлось — EPUB собирается без обложки (дефолтная серая заглушка Calibre подавлена флагом `--no-default-epub-cover`).

## Как работает

- macOS `launchd` отслеживает папку через `WatchPaths`.
- При появлении новых файлов запускается [`bin/fb2-to-epub-watcher.sh`](bin/fb2-to-epub-watcher.sh).
- Поиск обложек делает [`bin/fb2-to-epub-cover-finder.py`](bin/fb2-to-epub-cover-finder.py) — Python 3, без сторонних зависимостей.
- Конвертацию и чтение метаданных выполняет [Calibre](https://calibre-ebook.com) — CLI `ebook-convert` и `ebook-meta`.
- `ThrottleInterval=5s` сглаживает пакетное копирование, lock-каталог в `/tmp` сериализует параллельные запуски.

## Требования

- macOS
- [Calibre](https://calibre-ebook.com) — нужен `/Applications/calibre.app/Contents/MacOS/ebook-convert` и `ebook-meta`
- `python3` (входит в Xcode Command Line Tools: `xcode-select --install`)

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
├── bin/fb2-to-epub-watcher.sh                  — основной скрипт-watcher
├── bin/fb2-to-epub-cover-finder.py             — поиск и загрузка обложек (Google Books)
├── launchd/com.user.fb2-to-epub.plist.template — шаблон LaunchAgent (HOME подставляется install.sh)
├── install.sh                                  — установка + загрузка агента
└── uninstall.sh                                — снятие агента
```

## Лицензия

[MIT](LICENSE)
