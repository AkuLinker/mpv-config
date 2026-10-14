---Screenshot the video and copy it to the clipboard
---@author ObserverOfTime
---@license 0BSD
---
--- Locally patched:
---  * reports real success/failure (missing tool, failed screenshot) instead
---    of always saying "Copied"
---  * Wayland is also detected through WAYLAND_DISPLAY, not only
---    XDG_SESSION_TYPE
---  * temp folder taken from TMPDIR/TEMP with safe fallbacks
---
--- Requirements per OS:
---   Linux Wayland: wl-copy (package "wl-clipboard")
---   Linux X11:     xclip
---   Windows:       nothing (PowerShell is built in)
---   macOS:         nothing (osascript is built in)
---
--- input.conf example:
---   c       script-binding clipshot/clipshot-subs
---   C       script-binding clipshot/clipshot-video
---   Ctrl+c  script-binding clipshot/clipshot-window

---@class ClipshotOptions
---@field name string
---@field type string
local o = {
    name = 'mpv-screenshot.jpeg',
    type = '' -- defaults to jpeg
}
local mp = require 'mp'
local utils = require 'mp.utils'
require('mp.options').read_options(o, 'clipshot')

local file, cmd

local platform = mp.get_property_native('platform')
    or (package.config:sub(1, 1) == '\\' and 'windows' or 'linux')

if platform == 'windows' then
    file = utils.join_path(os.getenv('TEMP') or os.getenv('TMP') or 'C:\\Windows\\Temp', o.name)
    cmd = {
        'powershell', '-NoProfile', '-NonInteractive', '-Command',
        'Add-Type -Assembly System.Windows.Forms, System.Drawing;',
        string.format(
            "[Windows.Forms.Clipboard]::SetImage([Drawing.Image]::FromFile('%s'))",
            (file:gsub("'", "''"))
        )
    }
elseif platform == 'darwin' then
    file = utils.join_path(os.getenv('TMPDIR') or '/tmp', o.name)
    -- png: «class PNGf»
    local type = o.type ~= '' and o.type or 'JPEG picture'
    cmd = {
        'osascript', '-e', string.format(
            'set the clipboard to (read (POSIX file %q) as %s)',
            file, type
        )
    }
else
    file = utils.join_path(os.getenv('TMPDIR') or '/tmp', o.name)
    local wayland = os.getenv('XDG_SESSION_TYPE') == 'wayland'
        or (os.getenv('WAYLAND_DISPLAY') or '') ~= ''
    -- wl-copy and xclip stay in the background to serve the clipboard.
    -- Their output is redirected to /dev/null so that background process
    -- doesn't hold mpv's pipes open; the shell then exits right away and
    -- its exit code tells us whether the copy worked (127 = tool missing).
    if wayland then
        cmd = {'sh', '-c', 'wl-copy < "$1" >/dev/null 2>&1', 'sh', file}
    else
        local type = o.type ~= '' and o.type or 'image/jpeg'
        cmd = {'sh', '-c', 'xclip -sel c -t "$1" -i "$2" >/dev/null 2>&1', 'sh', type, file}
    end
end

local function tool_name()
    if platform == 'windows' then return 'PowerShell' end
    if platform == 'darwin' then return 'osascript' end
    return cmd[3]:match('^(%S+)')
end

---@param arg string
---@return fun()
local function clipshot(arg)
    return function()
        if not mp.commandv('screenshot-to-file', file, arg) then
            mp.osd_message('Screenshot failed', 2)
            return
        end
        mp.command_native_async({
            name = 'subprocess',
            args = cmd,
            playback_only = false,
            capture_stdout = false,
            capture_stderr = false,
        }, function(success, res, err)
            if success and res and res.status == 0 then
                mp.osd_message('Copied screenshot to clipboard', 1)
            elseif res and res.status == 127 then
                mp.osd_message('Clipboard tool not found: ' .. tool_name(), 3)
            else
                local reason = err or (res and res.error_string ~= '' and res.error_string)
                    or ('exit code ' .. tostring(res and res.status))
                mp.osd_message('Failed to copy screenshot: ' .. tostring(reason), 3)
            end
        end)
    end
end

mp.add_key_binding(nil,     'clipshot-subs',   clipshot('subtitles'))
mp.add_key_binding(nil,     'clipshot-video',  clipshot('video'))
mp.add_key_binding(nil,     'clipshot-window', clipshot('window'))
