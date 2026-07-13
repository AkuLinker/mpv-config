# mpv configs & scripts

## EN

My mpv configs and scripts.

### Scripts

- **[uosc](https://github.com/tomasklaen/uosc)** — The foundation. Handles the player UI.
- **[uosc_video_settings.lua](https://github.com/itsmeipg/mpv-config/blob/main/portable_config/scripts/uosc_video_settings.lua)** — uosc menu for adjusting video settings on the fly: aspect ratio override, deband, color (brightness, contrast, saturation, gamma, hue), deinterlace, dither, hardware decoding, scale (upscale/downscale/chroma/temporal filters and their parameters), video output (vo), video sync mode, and interpolation. Supports named profiles for aspect ratio, deband, and color presets.
- **[uosc_subtitle_settings.lua](https://github.com/itsmeipg/mpv-config/blob/main/portable_config/scripts/uosc_subtitle_settings.lua)** — uosc menu for adjusting subtitle style and behavior on the fly: font, size, color, outline/shadow color and size, bold/italic, border style, scale, spacing, blur, placement/alignment/margins, ASS override, subtitle blending, timing fix, and delay. Supports named style profiles, color presets, and font presets.
- **[thumbfast](https://github.com/po5/thumbfast)** — Adds thumbnail preview support above the progress bar.
- **[autoload](https://github.com/mpv-player/mpv/blob/master/TOOLS/lua/autoload.lua)** — Automatically adds videos from the current directory to the playlist.
- **[sub-transition](https://github.com/Ajatt-Tools/sub-transition)** — Speeds up or skips the video when there are no subtitles. Slightly modified the notification logic in `transitions.lua` to suit my taste.
- **[clipshot.lua](https://github.com/ObserverOfTime/mpv-scripts/blob/master/clipshot.lua)** — A convenient script for saving screenshots to the clipboard.
- **[memo.lua](https://github.com/po5/memo)** — Saves watch history, and displays it in a nice menu.
- **[keybind-visualizer.lua](https://github.com/v-amorim/mpv)** — Interactive on-screen keyboard/mouse overlay for mpv — press or hover any key/button to see what it's bound to, with a real-time layout switcher. I slightly modified the original script. Added the ability to toggle mpv's default bindings on and off, and to view them by pressing a key, not just by hovering with the mouse.

### Custom scripts

- **google-translate.lua** — Opens Google Translate in the browser with the current subtitle line.
- **time.lua** — Shows the estimated time at which the video will finish. Modified and shortened version of [this script](https://github.com/mustaqimM/mpv-scripts/blob/master/time.lua).
- **seek_display.lua** — Seeks and shows the actual position after the seek completes.
- **sub-search.lua** — Opens a searchable uosc menu with all subtitle lines and their timecodes. Then you can search and select any line to seek to that moment in the video.
- **cache_cleaner.lua** — Automatically deletes stale cache files (watch_later and shaders_cache) on player shutdown. When verbose logging is enabled, each session writes its own log file to cache/cache_cleaner_logs/. Old log files are also cleaned up automatically.
- **copy-video-info.lua** — Opens a uosc menu that lets you copy various pieces of information about the currently playing file to the system clipboard (video title, current subtitle, file path, timestamp, media info).

A variety of shaders from various sources are also included.

---

## RU

Мои mpv конфиги и скрипты.

### Скрипты

- **[uosc](https://github.com/tomasklaen/uosc)** — Основа. Отвечает за UI плеера.
- **[uosc_video_settings.lua](https://github.com/itsmeipg/mpv-config/blob/main/portable_config/scripts/uosc_video_settings.lua)** — uosc-меню для настройки видео на лету: переопределение соотношения сторон, деband, цвет (яркость, контраст, насыщенность, гамма, оттенок), деинтерлейс, дизеринг, аппаратное декодирование, масштабирование (фильтры апскейла/даунскейла/хромаскейла/темпорального скейла и их параметры), видеовывод (vo), режим синхронизации видео и интерполяция. Поддерживает именованные профили для соотношения сторон, деbandа и цветовых пресетов.
- **[uosc_subtitle_settings.lua](https://github.com/itsmeipg/mpv-config/blob/main/portable_config/scripts/uosc_subtitle_settings.lua)** — uosc-меню для настройки стиля и поведения субтитров на лету: шрифт, размер, цвет, цвет и размер контура/тени, жирный/курсив, стиль границы, масштаб, интервал, размытие, позиционирование/выравнивание/отступы, переопределение ASS, смешивание субтитров, исправление таймингов и задержка. Поддерживает именованные профили стиля, цветовые пресеты и пресеты шрифтов.
- **[thumbfast](https://github.com/po5/thumbfast)** — Добавляет поддержку миниатюр над полоской прогресса.
- **[autoload](https://github.com/mpv-player/mpv/blob/master/TOOLS/lua/autoload.lua)** — Добавляет в плейлист видео из текущей директории.
- **[sub-transition](https://github.com/Ajatt-Tools/sub-transition)** — Ускоряет или пропускает куски видео между субтитрами. Слегка изменена логика уведомлений в `transitions.lua`.
- **[clipshot.lua](https://github.com/ObserverOfTime/mpv-scripts/blob/master/clipshot.lua)** — Просто удобный скрипт для охранения скриншотов в клипборд.
- **[memo.lua](https://github.com/po5/memo)** — Сохраняет историю просмотренных видео и отображает это в красивом меню.
- **[keybind-visualizer.lua](https://github.com/v-amorim/mpv)** — Интерактивная оверлей-визуализация клавиатуры и мыши для mpv — наводишь курсор или нажимаешь любую клавишу/кнопку и сразу видишь, что на неё забиндчено. Я слегка поменял оригинальный скрипт. Добавлена возможность включения и выключения дефолтных байдингов mpv и просмотр при их нажимании а не только наведения мышкой.

### Свои скрипты

- **google-translate.lua** — Открывает Google Translate в браузере с текущим субтитром.
- **time.lua** — Показывает время окончания видео. Изменённая и сокращённая версия [этого скрипта](https://github.com/mustaqimM/mpv-scripts/blob/master/time.lua).
- **seek_display.lua** — Перемотка с отображением текущей позиции в видео.
- **sub-search.lua** — Открывает меню uosc со всеми строками субтитров и таймкодами. Позволяет отфильтровать и выбрать любую строку чтобы перемотать видео к этому моменту.
- **cache_cleaner.lua** — Автоматически удаляет устаревшие файлы кэша (watch_later и shaders_cache) при завершении плеера. При включённом подробном логировании каждая сессия пишет отдельный лог-файл в cache/cache_cleaner_logs/. Старые логи также удаляются автоматически.
- **copy-video-info.lua** — Открывает uosc меню позволяющее копировать в клипборд различную информацию из воспроизводимого видео (название, текущий субтитр, путь к файлу, текущий тамймстамп и медиа данные).

Также используются шейдеры из различных источников.
