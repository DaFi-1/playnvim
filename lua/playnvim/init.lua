local config = require("playnvim.config")
local state = require("playnvim.state")
local mpv = require("playnvim.mpv")
local ui = require("playnvim.ui")

local M = {}

M.setup = function(opts)
  config.setup(opts)
  state.load()
  local preview = require("playnvim.preview")
  preview.prefetch_playlist(state.get_playlist())
  if config.opts.keymap and type(config.opts.keymap) == "string" and config.opts.keymap ~= "" then
    vim.keymap.set("n", config.opts.keymap, ui.toggle, { silent = true, desc = "Alternar player PlayNvim" })
  end
end

M.open = ui.open
M.close = ui.close
M.toggle = ui.toggle
M.is_open = ui.is_open
M.set_layout = ui.set_layout
M.cycle_layout = ui.cycle_layout
M.get_layout = ui.get_layout

M.play = function(track_or_idx)
  if type(track_or_idx) == "number" then
    state.set_current_index(track_or_idx)
    mpv.play(state.get_current_track())
  elseif type(track_or_idx) == "table" then
    mpv.play(track_or_idx)
  else
    mpv.play()
  end
end

M.pause = mpv.pause
M.resume = mpv.resume
M.toggle_pause = mpv.toggle_pause
M.stop = mpv.stop
M.next = mpv.next
M.prev = mpv.prev
M.seek = mpv.seek
M.set_volume = mpv.set_volume
M.volume_up = mpv.volume_up
M.volume_down = mpv.volume_down
M.get_playback_info = mpv.get_playback_info

-- String formatada para statusline / lualine
M.status = function()
  local info = mpv.get_playback_info()
  if info.status == "stopped" then
    return ""
  end

  local icon = info.status == "playing" and "󰐊" or (info.status == "paused" and "󰏤" or "⠋")
  local title = info.short_title or (info.title and info.title ~= "" and info.title or "Áudio")
  return string.format("%s %s (%s/%s)", icon, title, info.formatted_time or "00:00", info.formatted_duration or "00:00")
end

return M
