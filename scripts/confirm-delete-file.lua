-- confirm-delete-file.lua
--
-- Requires: uosc (https://github.com/tomasklaen/uosc)
--
-- What this does:
-- uosc ships three built-in "delete file" bindings:
--   uosc/delete-file-quit  - delete current file, then quit mpv
--   uosc/delete-file-next  - delete current file, then play next
--   uosc/delete-file-prev  - delete current file, then play previous
-- All three delete immediately with no confirmation. That's fine when
-- triggered from a menu click, but risky if bound directly to a key
-- (an accidental press = an accidental delete).
--
-- This script wraps all three in a confirmation step using uosc's
-- native menu UI. Pressing a key opens a small "Yes / No" menu instead
-- of deleting right away. Only choosing "Yes" actually runs the
-- corresponding original uosc binding.
--
-- Setup:
-- 1. Save this file into your mpv scripts folder:
--        Linux/macOS: ~/.config/mpv/scripts/
--        Windows:     %APPDATA%\mpv\scripts\
-- 2. Bind keys to it in input.conf, for example:
--        DEL        script-binding confirm-delete-file-quit
--        ALT+DEL    script-binding confirm-delete-file-next
--        CTRL+DEL   script-binding confirm-delete-file-prev
--    (the binding name is <script_filename>/<name passed to add_key_binding>)

local mp    = require "mp"
local utils = require('mp.utils')

-- Opens a Yes/No uosc menu, and runs uosc_binding only if user confirms.
-- menu_type must be unique per menu (used internally by uosc).
-- question is the text shown as the menu title.
-- uosc_binding is the full uosc script-binding command to run on "Yes".
local function show_confirm(menu_type, question, uosc_binding)
    local menu = {
        type = menu_type,
        title = question,
        items = {
            {
                title = 'No, cancel',
                icon = 'close',
                value = 'ignore',
                active = false, -- safe option is selected by default
            },
            {
                title = 'Yes, delete',
                icon = 'delete',
                value = uosc_binding,
            },
        }
    }
    mp.commandv('script-message-to', 'uosc', 'open-menu', utils.format_json(menu))
end

local function confirm_delete_file_quit()
    show_confirm(
        'confirm-delete-file-quit',
        'Delete file and quit?',
        'script-binding uosc/delete-file-quit'
    )
end

local function confirm_delete_file_next()
    show_confirm(
        'confirm-delete-file-next',
        'Delete file and play next?',
        'script-binding uosc/delete-file-next'
    )
end

local function confirm_delete_file_prev()
    show_confirm(
        'confirm-delete-file-prev',
        'Delete file and play previous?',
        'script-binding uosc/delete-file-prev'
    )
end

mp.add_key_binding(nil, 'confirm-delete-file-quit', confirm_delete_file_quit)
mp.add_key_binding(nil, 'confirm-delete-file-next', confirm_delete_file_next)
mp.add_key_binding(nil, 'confirm-delete-file-prev', confirm_delete_file_prev)
