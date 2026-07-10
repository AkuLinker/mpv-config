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
-- Pause behavior:
-- - Opening the confirmation menu pauses playback, but only if it
--   wasn't already paused. We remember whether *we* were the one who
--   paused it (paused_by_us).
-- - When the menu closes - no matter how: "No", "Yes", or just pressing
--   Esc - we restore playback to what it would have been if we hadn't
--   touched it:
--     - If we were the one who paused it, we unpause.
--     - If it was already paused before we opened the menu, we leave it
--       paused.
-- - For "Yes" on delete-file-next / delete-file-prev specifically, the
--   file changes, so afterwards we explicitly force-resume regardless -
--   the new file should just start playing, not open paused.
-- - delete-file-quit doesn't need any of this since mpv exits.
--
-- Network/stream guard:
-- - "Delete" makes no sense for online video (YouTube and similar),
--   since there's no local file to remove - uosc would just be deleting
--   something in a cache/temp location, or doing nothing meaningful.
-- - Before opening the confirmation menu, the script checks mpv's
--   'demuxer-via-network' property. If the current media is being
--   streamed over the network, it shows a short on-screen message
--   instead ("Can't delete a network stream") and does not open the
--   confirmation menu or touch pause at all.
--
-- Setup:
-- 1. Save this file into your mpv scripts folder:
--        Linux/macOS: ~/.config/mpv/scripts/
--        Windows:     %APPDATA%\mpv\scripts\
-- 2. Bind keys to it in input.conf, for example:
--        DEL        script-binding confirm-delete-file/confirm-delete-file-quit
--        ALT+DEL    script-binding confirm-delete-file/confirm-delete-file-next
--        CTRL+DEL   script-binding confirm-delete-file/confirm-delete-file-prev
--    (the binding name is <script_filename>/<name passed to add_key_binding>)

local mp    = require "mp"
local utils = require('mp.utils')

local script_name = mp.get_script_name()

-- True if *this script* paused playback when the currently open confirmation
-- menu was shown (as opposed to it having already been paused by the user).
local paused_by_us = false

-- Called via on_close whenever any of our confirmation menus closes, no
-- matter the reason (Yes, No, Esc, clicking elsewhere, etc).
mp.register_script_message('confirm-delete-file-closed', function()
    if paused_by_us then
        mp.set_property_bool('pause', false)
        paused_by_us = false
    end
end)

-- Opens a Yes/No uosc menu, and runs uosc_binding only if user confirms.
-- menu_type must be unique per menu (used internally by uosc).
-- question is the text shown as the menu title.
-- uosc_binding is the full uosc script-binding command to run on "Yes".
-- resume_after: if true, playback is explicitly force-resumed right after
-- the "Yes" command runs (used for next/prev, where a new file starts
-- playing and shouldn't inherit whatever pause state was in effect).
local function show_confirm(menu_type, question, uosc_binding, resume_after)
    -- Refuse to even open the dialog for network streams (e.g. YouTube) -
    -- there's no local file to delete, so don't pause or ask anything.
    if mp.get_property_bool('demuxer-via-network', false) then
        mp.osd_message("Can't delete: this is a network stream, not a local file.", 3)
        return
    end

    -- Pause playback while the confirmation dialog is open, unless it's
    -- already paused. Remember whether we're the one who paused it, so we
    -- know whether to undo that once the menu closes.
    if mp.get_property_bool('pause') then
        paused_by_us = false
    else
        mp.set_property_bool('pause', true)
        paused_by_us = true
    end

    local yes_value = uosc_binding
    if resume_after then
        -- Chain a forced unpause right after the delete+navigate command, so
        -- the next/previous file plays immediately instead of opening paused.
        yes_value = uosc_binding .. '; set pause no'
    end

    local menu = {
        type = menu_type,
        title = question,
        -- Runs when the menu closes for any reason, restoring pause state.
        on_close = 'script-message-to ' .. script_name .. ' confirm-delete-file-closed',
        items = {
            {
                title = 'Yes, delete',
                icon = 'delete',
                value = yes_value,
            },
            {
                title = 'No, cancel',
                icon = 'close',
                value = 'ignore',
                active = false,
            },
        }
    }
    mp.commandv('script-message-to', 'uosc', 'open-menu', utils.format_json(menu))
end

local function confirm_delete_file_quit()
    show_confirm(
        'confirm-delete-file-quit',
        'Delete file and quit?',
        'script-binding uosc/delete-file-quit',
        false
    )
end

local function confirm_delete_file_next()
    show_confirm(
        'confirm-delete-file-next',
        'Delete file and play next?',
        'script-binding uosc/delete-file-next',
        true
    )
end

local function confirm_delete_file_prev()
    show_confirm(
        'confirm-delete-file-prev',
        'Delete file and play previous?',
        'script-binding uosc/delete-file-prev',
        true
    )
end

mp.add_key_binding(nil, 'confirm-delete-file-quit', confirm_delete_file_quit)
mp.add_key_binding(nil, 'confirm-delete-file-next', confirm_delete_file_next)
mp.add_key_binding(nil, 'confirm-delete-file-prev', confirm_delete_file_prev)
