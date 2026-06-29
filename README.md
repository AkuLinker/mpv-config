# mpv configs & scripts

## EN

My mpv configs and scripts.

### Scripts

- **[uosc](https://github.com/tomasklaen/uosc)** — The foundation. Handles the player UI.
- **[thumbfast](https://github.com/po5/thumbfast)** — Adds thumbnail preview support above the progress bar.
- **[autoload](https://github.com/mpv-player/mpv/blob/master/TOOLS/lua/autoload.lua)** — Automatically adds videos from the current directory to the playlist.
- **[sub-transition](https://github.com/Ajatt-Tools/sub-transition)** — Speeds up or skips the video when there are no subtitles. Slightly modified the notification logic in `transitions.lua` to suit my taste.
- **[clipshot.lua](https://github.com/ObserverOfTime/mpv-scripts/blob/master/clipshot.lua)** — A convenient script for saving screenshots to the clipboard.
- **[memo.lua](https://github.com/po5/memo)** — Saves watch history, and displays it in a nice menu.

### Custom scripts

- **google-translate.lua** — Opens Google Translate in the browser with the current subtitle line.
- **time.lua** — Shows the estimated time at which the video will finish. Modified and shortened version of [this script](https://github.com/mustaqimM/mpv-scripts/blob/master/time.lua).
- **seek_display.lua** — Seeks and shows the actual position after the seek completes.
- **sub-search.lua** — Opens a searchable uosc menu with all subtitle lines and their timecodes. Then you can search and select any line to seek to that moment in the video.
- **cache_cleaner.lua** — Automatically deletes stale cache files (watch_later and shaders_cache) on player shutdown. When verbose logging is enabled, each session writes its own log file to cache/cache_cleaner_logs/. Old log files are also cleaned up automatically.

A variety of shaders from various sources are also included.

---

## RU

Мои mpv конфиги и скрипты.

### Скрипты

- **[uosc](https://github.com/tomasklaen/uosc)** — Основа. Отвечает за UI плеера.
- **[thumbfast](https://github.com/po5/thumbfast)** — Добавляет поддержку миниатюр над полоской прогресса.
- **[autoload](https://github.com/mpv-player/mpv/blob/master/TOOLS/lua/autoload.lua)** — Добавляет в плейлист видео из текущей директории.
- **[sub-transition](https://github.com/Ajatt-Tools/sub-transition)** — Ускоряет или пропускает куски видео между субтитрами. Слегка изменена логика уведомлений в `transitions.lua`.
- **[clipshot.lua](https://github.com/ObserverOfTime/mpv-scripts/blob/master/clipshot.lua)** — Просто удобный скрипт для охранения скриншотов в клипборд.
- **[memo.lua](https://github.com/po5/memo)** — Сохраняет историю просмотренных видео и отображает это в красивом меню.

### Свои скрипты

- **google-translate.lua** — Открывает Google Translate в браузере с текущим субтитром.
- **time.lua** — Показывает время окончания видео. Изменённая и сокращённая версия [этого скрипта](https://github.com/mustaqimM/mpv-scripts/blob/master/time.lua).
- **seek_display.lua** — Перемотка с отображением текущей позиции в видео.
- **sub-search.lua** — Открывает меню uosc со всеми строками субтитров и таймкодами. Позволяет отфильтровать и выбрать любую строку чтобы перемотать видео к этому моменту.
- **cache_cleaner.lua** — Автоматически удаляет устаревшие файлы кэша (watch_later и shaders_cache) при завершении плеера. При включённом подробном логировании каждая сессия пишет отдельный лог-файл в cache/cache_cleaner_logs/. Старые логи также удаляются автоматически.

Также используются шейдеры из различных источников.
