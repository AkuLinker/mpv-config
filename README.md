# mpv configs & scripts

## EN

My mpv configs and scripts.

### Scripts

- **[uosc](https://github.com/tomasklaen/uosc)** — The foundation. Handles the player UI.
- **[thumbfast](https://github.com/po5/thumbfast)** — Adds thumbnail preview support above the progress bar.
- **[autoload](https://github.com/mpv-player/mpv/blob/master/TOOLS/lua/autoload.lua)** — Automatically adds videos from the current directory to the playlist.
- **[sub-transition](https://github.com/Ajatt-Tools/sub-transition)** — Speeds up or skips the video when there are no subtitles. Slightly modified the notification logic in `transitions.lua` to suit my taste.
- **[libass_sub_selector](https://github.com/po5/libass_sub_selector)** — Allows you to highlight subtitles and copy them like in PotPlayer. The original script is quite outdated — modernized and reworked it a bit, also changed the copy logic from Windows to Linux. You may need to specify the libass path in `script-opts/libass_sub_selector.conf`. Dependencies: `libass`, `ffmpeg`, `mkvtoolnix-cli` (mkvmerge + mkvextract), `wl-clipboard` (wl-copy). Works only with ASS.

### Custom scripts

- **google-translate.lua** — Opens Google Translate in the browser with the current subtitle line.
- **sub-bg-toggle.lua** — Toggles a black background behind subtitles with a single key press.
- **time.lua** — Shows the estimated time at which the video will finish. Modified and shortened version of [this script](https://github.com/mustaqimM/mpv-scripts/blob/master/time.lua).
- **seek_display.lua** — Seeks and shows the actual position after the seek completes.

A variety of shaders from various sources are also included.

---

## RU

Мои mpv конфиги и скрипты.

### Скрипты

- **[uosc](https://github.com/tomasklaen/uosc)** — Основа. Отвечает за UI плеера.
- **[thumbfast](https://github.com/po5/thumbfast)** — Добавляет поддержку миниатюр над полоской прогресса.
- **[autoload](https://github.com/mpv-player/mpv/blob/master/TOOLS/lua/autoload.lua)** — Добавляет в плейлист видео из текущей директории.
- **[sub-transition](https://github.com/Ajatt-Tools/sub-transition)** — Ускоряет или пропускает куски видео между субтитрами. Слегка изменена логика уведомлений в `transitions.lua`.
- **[libass_sub_selector](https://github.com/po5/libass_sub_selector)** — Позволяет выделить субтитры и скопировать их как в PotPlayer. Оригинальный скрипт устарел — немного осовременил и переделал, также изменил логику копирования с Windows на Linux. В `script-opts/libass_sub_selector.conf` может потребоваться указать путь к libass. Зависимости: `libass`, `ffmpeg`, `mkvtoolnix-cli` (mkvmerge + mkvextract), `wl-clipboard` (wl-copy). Работает только с ASS.

### Свои скрипты

- **google-translate.lua** — Открывает Google Translate в браузере с текущим субтитром.
- **sub-bg-toggle.lua** — Переключает чёрный фон за субтитрами одной кнопкой.
- **time.lua** — Показывает время окончания видео. Изменённая и сокращённая версия [этого скрипта](https://github.com/mustaqimM/mpv-scripts/blob/master/time.lua).
- **seek_display.lua** — Перемотка с отображением текущей позиции в видео.

Также используются шейдеры из различных источников.
