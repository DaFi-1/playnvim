local config = require("playnvim.config")
local state = require("playnvim.state")
local mpv = require("playnvim.mpv")
local preview = require("playnvim.preview")
local db = require("playnvim.db")

local M = {}

local ns_id = vim.api.nvim_create_namespace("musicnvim_ui")
local uv = vim.uv or vim.loop

local win = nil
local buf = nil
local vol_win = nil
local vol_buf = nil
local vol_ns_id = vim.api.nvim_create_namespace("musicnvim_vol")
local thumb_win = nil
local thumb_buf = nil
local thumb_ns_id = vim.api.nvim_create_namespace("musicnvim_thumb")
local current_loaded_thumb_url = nil
local current_cached_thumb_png = nil
local thumb_needs_draw = false
local active_pane = "list" -- "toolbar" or "list"
local toolbar_idx = 3      -- 1: Reiniciar, 2: Pause, 3: Player, 4: Vol +, 5: Vol -, 6: Help
local selected_idx = 1     -- 1..N: músicas da playlist
local list_start = 1
local resize_autocmd = nil
local resize_timer = nil
local help_win = nil
local help_buf = nil
local is_opening_dialog = false
local anim_timer = nil

local str_rep = string.rep
local str_format = string.format
local str_displaywidth = vim.fn.strdisplaywidth
local math_min = math.min
local math_max = math.max
local math_floor = math.floor

local EQ_CHARS = { " ", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
local NUM_EQ_BARS = 6
local eq_levels = { 6, 11, 15, 9, 7, 4 }
local top_buf = { " ", " ", " ", " ", " ", " " }
local bot_buf = { " ", " ", " ", " ", " ", " " }

local paused_top = nil
local paused_bot = nil

local function get_equalizer_frames(status)
  if status == "stopped" then
    paused_top, paused_bot = nil, nil
    return "      ", "▂▃▂▃▂▂"
  elseif status == "paused" then
    if paused_top and paused_bot then
      return paused_top, paused_bot
    end
    for i = 1, NUM_EQ_BARS do
      local lvl = eq_levels[i]
      if lvl <= 8 then
        bot_buf[i] = EQ_CHARS[lvl]
        top_buf[i] = " "
      else
        bot_buf[i] = "█"
        top_buf[i] = EQ_CHARS[lvl - 8]
      end
    end
    paused_top = table.concat(top_buf)
    paused_bot = table.concat(bot_buf)
    return paused_top, paused_bot
  elseif status == "buffering" then
    paused_top, paused_bot = nil, nil
    local t = math_floor((uv.hrtime() / 1e8)) % 8
    for i = 1, NUM_EQ_BARS do
      local idx = ((t + i) % 7) + 2
      bot_buf[i] = EQ_CHARS[idx]
    end
    return "      ", table.concat(bot_buf)
  else -- "playing": se movimenta apenas quando tiver tocando!
    paused_top, paused_bot = nil, nil
    for i = 1, NUM_EQ_BARS do
      local delta = math.random(-3, 3)
      local lvl = math_max(1, math_min(16, eq_levels[i] + delta))
      eq_levels[i] = lvl
      if lvl <= 8 then
        bot_buf[i] = EQ_CHARS[lvl]
        top_buf[i] = " "
      else
        bot_buf[i] = "█"
        top_buf[i] = EQ_CHARS[lvl - 8]
      end
    end
    return table.concat(top_buf), table.concat(bot_buf)
  end
end

local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local function get_spinner_frame()
  local t = math_floor(uv.hrtime() / 1e8)
  local idx = (t % #SPINNER_FRAMES) + 1
  return SPINNER_FRAMES[idx]
end

-- Toolbar options without brackets []
local TOOLBAR_OPTIONS = {
  { id = "restart", label = " 󰑓 " },
  { id = "pause",   label = " 󰏤 " },
  { id = "play",    label = " 󰐊 " },
  { id = "vol_up",  label = " + " },
  { id = "vol_dn",  label = " - " },
  { id = "help",    label = " 󰋖 " },
}

local total_toolbar_btn_len = 0
for _, b in ipairs(TOOLBAR_OPTIONS) do
  b.width = str_displaywidth(b.label)
  total_toolbar_btn_len = total_toolbar_btn_len + b.width
end

local hl_initialized = false
local function setup_highlights()
  if hl_initialized then
    return
  end
  hl_initialized = true

  local set_hl = vim.api.nvim_set_hl
  -- Paleta base #ffffff e #000000
  set_hl(0, "MusicNvimNormal", { bg = "#000000", fg = "#ffffff", default = true })
  set_hl(0, "MusicNvimBorder", { bg = "#000000", fg = "#ffffff", default = true })
  set_hl(0, "MusicNvimTitle", { bg = "#000000", fg = "#ffffff", bold = true, default = true })
  set_hl(0, "MusicNvimPlaying", { bg = "#000000", fg = "#ffffff", bold = true, default = true })
  set_hl(0, "MusicNvimPaused", { bg = "#000000", fg = "#ffffff", default = true })
  set_hl(0, "MusicNvimBuffering", { bg = "#000000", fg = "#ffffff", bold = true, default = true })
  set_hl(0, "MusicNvimMuted", { bg = "#000000", fg = "#ffffff", default = true })
  set_hl(0, "MusicNvimProgressFill", { bg = "#000000", fg = "#ffffff", bold = true, default = true })
  set_hl(0, "MusicNvimProgressEmpty", { bg = "#000000", fg = "#ffffff", default = true })
  set_hl(0, "MusicNvimVolume", { bg = "#000000", fg = "#ffffff", bold = true, default = true })
  set_hl(0, "MusicNvimVolumeFill", { bg = "#000000", fg = "#ffffff", bold = true, default = true })
  set_hl(0, "MusicNvimVolumeEmpty", { bg = "#000000", fg = "#ffffff", default = true })

  -- Equalizer animation highlight: SEMPRE VERDE (#50fa7b)
  set_hl(0, "MusicNvimEqualizer", { bg = "#000000", fg = "#50fa7b", bold = true, default = true })
  set_hl(0, "MusicNvimEqualizerPaused", { bg = "#000000", fg = "#50fa7b", bold = true, default = true })

  -- Buttons highlights
  set_hl(0, "MusicNvimBtn", { bg = "#000000", fg = "#ffffff", default = true })
  set_hl(0, "MusicNvimBtnActive", { bg = "#ffffff", fg = "#000000", bold = true, default = true })

  -- Selected item highlights (inverso: texto preto, fundo branco)
  set_hl(0, "MusicNvimSelected", { bg = "#ffffff", fg = "#000000", bold = true, default = true })
  set_hl(0, "MusicNvimSelectedPlaying", { bg = "#ffffff", fg = "#000000", bold = true, default = true })
  set_hl(0, "MusicNvimSelectedPaused", { bg = "#ffffff", fg = "#000000", bold = true, default = true })
  set_hl(0, "MusicNvimThumbTitle", { bg = "#000000", fg = "#ffffff", bold = true, default = true })
end

local LAYOUT_NAMES = {
  classic = "classic",
  default = "classic",
  standard = "classic",
  padrao = "classic",

  external = "external",
  window = "external",
  split = "external",
  externo = "external",

  embedded = "embedded",
  inline = "embedded",
  compact = "embedded",
  embutido = "embedded",
}

local current_layout = nil

local function get_layout()
  if config.opts.thumbnail == false then
    return "classic"
  end
  local l = current_layout or config.opts.layout or "embedded"
  return LAYOUT_NAMES[string.lower(tostring(l))] or "embedded"
end

local cached_geom = nil
local last_cols = 0
local last_lines = 0

local function calc_size()
  local cols = vim.o.columns
  local lines = vim.o.lines
  local layout = get_layout()

  if cached_geom and cols == last_cols and lines == last_lines and cached_geom.layout == layout then
    return cached_geom
  end
  last_cols = cols
  last_lines = lines

  local vol_w = 5
  local vol_total = vol_w + 2
  local gap = 1

  local default_h = config.opts.height or 18
  local max_h = math_max(8, lines - 4)
  local height = math_min(default_h, max_h)
  local row = math_max(0, math_floor((lines - height - 2) / 2))

  local show_thumb_win = false
  local thumb_w = 0
  local thumb_col = 0
  local width = 0
  local main_col = 0
  local vol_col = 0
  local has_thumb = false
  local thumb_h = 0
  local thumb_gap = 0
  local thumb_total = 0
  local right_width = 0

  if layout == "external" then
    show_thumb_win = (cols >= 80)
    thumb_w = show_thumb_win and math_min(config.opts.thumb_width or 30, math_floor(cols * 0.35)) or 0
    local thumb_ext_total = show_thumb_win and (thumb_w + 2) or 0

    local default_w = config.opts.width or 66
    local reserved = vol_total + gap + 4 + (show_thumb_win and (thumb_ext_total + gap) or 0)
    local max_w = math_max(28, cols - reserved)
    width = math_min(default_w, max_w)

    local total_w = (show_thumb_win and (thumb_ext_total + gap) or 0) + width + 2 + gap + vol_total
    local start_col = math_max(0, math_floor((cols - total_w) / 2))

    thumb_col = start_col
    main_col = show_thumb_win and (thumb_col + thumb_ext_total + gap) or start_col
    vol_col = main_col + width + 2 + gap
    if vol_col + vol_total > cols then
      vol_col = math_max(0, cols - vol_total)
      main_col = math_max(0, vol_col - width - 2 - gap)
    end

    has_thumb = false
    thumb_total = 0
    right_width = width
  elseif layout == "classic" then
    local default_w = config.opts.width or 66
    local max_w = math_max(28, cols - vol_total - gap - 4)
    width = math_min(default_w, max_w)

    local total_w = width + 2 + gap + vol_total
    main_col = math_max(0, math_floor((cols - total_w) / 2))
    vol_col = main_col + width + 2 + gap
    if vol_col + vol_total > cols then
      vol_col = math_max(0, cols - vol_total)
      main_col = math_max(0, vol_col - width - 2 - gap)
    end

    has_thumb = false
    thumb_total = 0
    right_width = width
    show_thumb_win = false
  else -- "embedded"
    local default_w = config.opts.width or 76
    local max_w = math_max(28, cols - vol_total - gap - 4)
    width = math_min(default_w, max_w)

    local total_w = width + 2 + gap + vol_total
    main_col = math_max(0, math_floor((cols - total_w) / 2))
    vol_col = main_col + width + 2 + gap
    if vol_col + vol_total > cols then
      vol_col = math_max(0, cols - vol_total)
      main_col = math_max(0, vol_col - width - 2 - gap)
    end

    has_thumb = (width >= 60 and cols >= 60)
    thumb_w = has_thumb and 22 or 0
    thumb_h = has_thumb and 6 or 0
    local thumb_left_margin = has_thumb and 1 or 0
    thumb_gap = has_thumb and 2 or 0
    thumb_total = thumb_left_margin + thumb_w + thumb_gap
    right_width = width - thumb_total
    show_thumb_win = false
  end

  cached_geom = {
    layout = layout,
    width = width,
    height = height,
    col = main_col,
    row = row,
    vol_col = vol_col,
    vol_width = vol_w,
    show_thumb_win = show_thumb_win,
    thumb_col = thumb_col,
    thumb_width = thumb_w,
    thumb_height = thumb_h,
    has_thumb = has_thumb,
    thumb_total = thumb_total,
    right_width = right_width,
  }
  return cached_geom
end

local last_rendered_vol = -1
local last_rendered_vol_h = -1

local function render_volume(geom, info)
  if not vol_win or not vim.api.nvim_win_is_valid(vol_win) then
    return
  end
  if not vol_buf or not vim.api.nvim_buf_is_valid(vol_buf) then
    return
  end

  local vol = math_min(100, math_max(0, info.volume or 30))
  local vol_w = geom.vol_width
  local height = geom.height

  -- O(1) guard: do not redraw volume if volume and height haven't changed
  if vol == last_rendered_vol and height == last_rendered_vol_h then
    return
  end
  last_rendered_vol = vol
  last_rendered_vol_h = height

  local vol_lines = {}

  -- Line 1: Icon (󰕾, 󰖀, 󰝟)
  local vol_icon = vol > 50 and "󰕾" or (vol > 0 and "󰖀" or "󰝟")
  local icon_disp_w = str_displaywidth(vol_icon)
  local pad_icon_l = math_max(0, math_floor((vol_w - icon_disp_w) / 2))
  local pad_icon_r = math_max(0, vol_w - icon_disp_w - pad_icon_l)
  table.insert(vol_lines, str_rep(" ", pad_icon_l) .. vol_icon .. str_rep(" ", pad_icon_r))

  -- Line 2: Spacer
  table.insert(vol_lines, str_rep(" ", vol_w))

  -- Vertical bar lines: from Line 3 to Line (height - 2)
  local num_bar = math_max(1, height - 4)
  local filled_count = math_floor((vol / 100) * num_bar + 0.5)
  if vol > 0 and filled_count == 0 then
    filled_count = 1
  end

  -- The bar fills from bottom to top!
  for b = 1, num_bar do
    local from_bottom = num_bar - b + 1
    local is_filled = (from_bottom <= filled_count)
    local char = is_filled and "█" or "░"
    local bar_disp_w = str_displaywidth(char)
    local pad_l = math_max(0, math_floor((vol_w - bar_disp_w) / 2))
    local pad_r = math_max(0, vol_w - bar_disp_w - pad_l)
    table.insert(vol_lines, str_rep(" ", pad_l) .. char .. str_rep(" ", pad_r))
  end

  -- Line (height - 1): Spacer
  table.insert(vol_lines, str_rep(" ", vol_w))

  -- Line height: Percentage (ex: " 30% ")
  local pct_str = str_format("%d%%", vol)
  local pct_disp_w = str_displaywidth(pct_str)
  local pad_pct_l = math_max(0, math_floor((vol_w - pct_disp_w) / 2))
  local pad_pct_r = math_max(0, vol_w - pct_disp_w - pad_pct_l)
  table.insert(vol_lines, str_rep(" ", pad_pct_l) .. pct_str .. str_rep(" ", pad_pct_r))

  while #vol_lines < height do
    table.insert(vol_lines, str_rep(" ", vol_w))
  end

  vim.api.nvim_buf_set_lines(vol_buf, 0, -1, false, vol_lines)

  -- Highlights for volume window
  vim.api.nvim_buf_clear_namespace(vol_buf, vol_ns_id, 0, -1)
  -- Icon line
  vim.api.nvim_buf_add_highlight(vol_buf, vol_ns_id, "MusicNvimVolumeFill", 0, 0, -1)
  -- Bar lines
  for b = 1, num_bar do
    local l_idx = 1 + b
    local from_bottom = num_bar - b + 1
    local is_filled = (from_bottom <= filled_count)
    local hl = is_filled and "MusicNvimVolumeFill" or "MusicNvimVolumeEmpty"
    vim.api.nvim_buf_add_highlight(vol_buf, vol_ns_id, hl, l_idx, 0, -1)
  end
  -- Bottom percentage line
  vim.api.nvim_buf_add_highlight(vol_buf, vol_ns_id, "MusicNvimVolumeFill", height - 1, 0, -1)
end

local trunc_cache = {}
local trunc_cache_count = 0

local function truncate_text(str, max_len)
  if not str or max_len <= 0 then
    return ""
  end
  local key = str .. "\0" .. max_len
  local cached = trunc_cache[key]
  if cached then
    return cached
  end

  if str_displaywidth(str) <= max_len then
    if trunc_cache_count > 256 then
      trunc_cache = {}
      trunc_cache_count = 0
    end
    trunc_cache[key] = str
    trunc_cache_count = trunc_cache_count + 1
    return str
  end

  local target_w = max_len - 1
  if target_w <= 0 then
    return "…"
  end

  local num_chars = vim.fn.strchars(str)
  local low = 1
  local high = num_chars
  local best = 1

  while low <= high do
    local mid = math_floor((low + high) / 2)
    local byte_len = vim.str_byteindex(str, mid)
    local sub = str:sub(1, byte_len)
    if str_displaywidth(sub) <= target_w then
      best = mid
      low = mid + 1
    else
      high = mid - 1
    end
  end

  local byte_len = vim.str_byteindex(str, best)
  local res = str:sub(1, byte_len) .. "…"
  if trunc_cache_count > 256 then
    trunc_cache = {}
    trunc_cache_count = 0
  end
  trunc_cache[key] = res
  trunc_cache_count = trunc_cache_count + 1
  return res
end

local pb_cache = {}
local pb_cache_count = 0
local function render_progress_bar(percent, bar_width)
  percent = math_min(100, math_max(0, percent or 0))
  bar_width = math_max(8, bar_width)
  local filled = math_floor((percent / 100) * bar_width)
  local key = filled * 1000 + bar_width
  local cached = pb_cache[key]
  if cached then
    return cached
  end
  local empty = bar_width - filled
  local res = str_rep("█", filled) .. str_rep("░", empty)
  if pb_cache_count > 512 then
    pb_cache = {}
    pb_cache_count = 0
  end
  pb_cache[key] = res
  pb_cache_count = pb_cache_count + 1
  return res
end

local expanded_folders = {}
local cached_visible_items = nil
local cached_visible_version = -1
local cached_grouped_folders = nil
local cached_grouped_version = -1

local function invalidate_visible_cache()
  cached_visible_items = nil
end

local function set_folder_expanded(name, val)
  if expanded_folders[name] ~= val then
    expanded_folders[name] = val
    invalidate_visible_cache()
  end
end

local function toggle_folder(name)
  expanded_folders[name] = not (expanded_folders[name] == true)
  invalidate_visible_cache()
end

local function group_playlist_folders(playlist)
  local cur_version = state.get_playlist_version()
  if cached_grouped_folders and cached_grouped_version == cur_version then
    return cached_grouped_folders
  end

  local folder_order = {}
  local folder_map = {}

  for i, track in ipairs(playlist) do
    local fname = (track.playlist and track.playlist ~= "") and track.playlist or "Geral"
    if not folder_map[fname] then
      folder_map[fname] = {
        name = fname,
        tracks = {},
      }
      table.insert(folder_order, fname)
    end
    table.insert(folder_map[fname].tracks, {
      track = track,
      original_idx = i,
    })
  end

  local result = {}
  for _, fname in ipairs(folder_order) do
    table.insert(result, folder_map[fname])
  end

  cached_grouped_folders = result
  cached_grouped_version = cur_version
  return result
end

local function build_visible_items(playlist)
  local cur_version = state.get_playlist_version()
  if cached_visible_items and cached_visible_version == cur_version then
    return cached_visible_items
  end

  local folders = group_playlist_folders(playlist)
  local items = {}

  for _, folder in ipairs(folders) do
    local is_expanded = (expanded_folders[folder.name] == true)
    table.insert(items, {
      type = "folder",
      name = folder.name,
      count = #folder.tracks,
      first_track = folder.tracks[1] and folder.tracks[1].track,
      is_expanded = is_expanded,
    })

    if is_expanded then
      for _, t_entry in ipairs(folder.tracks) do
        table.insert(items, {
          type = "track",
          track = t_entry.track,
          original_idx = t_entry.original_idx,
          folder_name = folder.name,
        })
      end
    end
  end

  cached_visible_items = items
  cached_visible_version = cur_version
  return items
end

-- Unified thumbnail synchronizer (single source of truth for Kitty image rendering)
local function sync_thumbnail(target_win, track, row_offset, col_offset, max_w, max_h)
  if not target_win or not vim.api.nvim_win_is_valid(target_win) then
    return
  end

  local track_url = track and track.url
  if not track_url then
    if current_loaded_thumb_url then
      preview.clear_image()
      current_loaded_thumb_url = nil
      current_cached_thumb_png = nil
    end
    return
  end

  local current_png = current_cached_thumb_png
  if not current_png and track_url then
    current_png = db.get(track_url)
    if current_png then
      current_cached_thumb_png = current_png
    end
  end

  if track_url ~= current_loaded_thumb_url then
    current_loaded_thumb_url = track_url
    current_cached_thumb_png = nil
    thumb_needs_draw = true
    preview.clear_image()
    preview.get_thumbnail(track, function(png_path)
      if png_path and M.is_open() and target_win and vim.api.nvim_win_is_valid(target_win) then
        if track_url == current_loaded_thumb_url then
          current_cached_thumb_png = png_path
          preview.render_image(target_win, png_path, row_offset, col_offset, max_w, max_h, true)
          thumb_needs_draw = false
        end
      end
    end)
  elseif current_png then
    preview.render_image(target_win, current_png, row_offset, col_offset, max_w, max_h, thumb_needs_draw)
    thumb_needs_draw = false
  end
end

local function update_thumbnail_image(geom, track)
  if not geom.has_thumb or not win or not vim.api.nvim_win_is_valid(win) then
    preview.clear_image()
    current_loaded_thumb_url = nil
    current_cached_thumb_png = nil
    return
  end
  sync_thumbnail(win, track, 1, 2, geom.thumb_width, geom.thumb_height)
end

local function render_thumb_window(geom, track)
  if not geom.show_thumb_win or not thumb_win or not vim.api.nvim_win_is_valid(thumb_win) then
    return
  end
  if not thumb_buf or not vim.api.nvim_buf_is_valid(thumb_buf) then
    return
  end

  local width = geom.thumb_width
  local height = geom.height
  local title = track and track.title or "Sem mídia"

  local lines = {}
  table.insert(lines, str_rep(" ", width))

  local header_str = "  󰐊 THUMBNAIL"
  table.insert(lines, header_str .. str_rep(" ", math_max(0, width - str_displaywidth(header_str))))
  table.insert(lines, str_rep(" ", width))

  local img_w = math_max(10, width - 2)
  local img_h = math_min(height - 6, math_max(6, math_floor(img_w / 3.0)))
  local top_offset = 3

  for _ = 1, img_h do
    table.insert(lines, str_rep(" ", width))
  end

  while #lines < height - 2 do
    table.insert(lines, str_rep(" ", width))
  end

  local short_t = truncate_text(title, width - 6)
  local footer_str = str_format("    %s", short_t)
  table.insert(lines, footer_str .. str_rep(" ", math_max(0, width - str_displaywidth(footer_str))))

  while #lines < height do
    table.insert(lines, str_rep(" ", width))
  end

  vim.api.nvim_buf_set_lines(thumb_buf, 0, -1, false, lines)

  vim.api.nvim_buf_clear_namespace(thumb_buf, thumb_ns_id, 0, -1)
  vim.api.nvim_buf_add_highlight(thumb_buf, thumb_ns_id, "MusicNvimThumbTitle", 1, 0, -1)
  if #lines >= height - 1 then
    vim.api.nvim_buf_add_highlight(thumb_buf, thumb_ns_id, "MusicNvimPlaying", #lines - 2, 0, -1)
  end

  sync_thumbnail(thumb_win, track, top_offset, 2, img_w, img_h)
end

function M.is_open()
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local STATUS_LABELS = {
  playing = "Playing",
  paused = "Paused",
  buffering = "Buffering...",
  stopped = "Stopped",
}

local cached_tb_width = -1
local cached_tb_has_thumb = nil
local cached_tb_line = ""
local cached_tb_positions = {}
local cached_blank_line = ""

local stop_anim_timer
local start_anim_timer
local render

stop_anim_timer = function()
  if anim_timer then
    anim_timer:stop()
    if not anim_timer:is_closing() then
      anim_timer:close()
    end
    anim_timer = nil
  end
end

start_anim_timer = function()
  if anim_timer then
    return
  end
  anim_timer = uv.new_timer()
  -- 100ms interval para animação fluida do spinner e equalizador
  anim_timer:start(100, 100, vim.schedule_wrap(function()
    if M.is_open() then
      local info = mpv.get_playback_info()
      if info.status == "playing" or info.status == "buffering" then
        render()
      else
        stop_anim_timer()
      end
    else
      stop_anim_timer()
    end
  end))
end

-- Helper 1: Toolbar line generator with displaywidth memoization
local function get_toolbar_line(width, right_w, thumb_prefix)
  if width == cached_tb_width and cached_tb_has_thumb == (thumb_prefix ~= "") then
    return cached_tb_line, cached_tb_positions
  end
  cached_tb_width = width
  cached_tb_has_thumb = (thumb_prefix ~= "")
  cached_blank_line = str_rep(" ", width)

  local total_rem = math_max(0, right_w - total_toolbar_btn_len)
  local num_gaps = #TOOLBAR_OPTIONS + 1
  local base_spacing = math_floor(total_rem / num_gaps)
  local extra = total_rem % num_gaps

  local tb_right = ""
  local tb_pos = {}
  for i = 1, num_gaps do
    local sp = base_spacing + (i <= extra and 1 or 0)
    tb_right = tb_right .. str_rep(" ", sp)
    if TOOLBAR_OPTIONS[i] then
      local b = TOOLBAR_OPTIONS[i]
      local start_byte = #thumb_prefix + #tb_right
      tb_right = tb_right .. b.label
      local end_byte = #thumb_prefix + #tb_right
      table.insert(tb_pos, {
        start_col = start_byte,
        end_col = end_byte,
      })
    end
  end
  local rem_tb = math_max(0, right_w - str_displaywidth(tb_right))
  if rem_tb > 0 then
    tb_right = tb_right .. str_rep(" ", rem_tb)
  end

  cached_tb_line = thumb_prefix .. tb_right
  cached_tb_positions = tb_pos
  return cached_tb_line, cached_tb_positions
end

-- Helper 2: Top header lines (Now playing, progress bar, equalizers)
local function render_header_section(info, right_w, thumb_prefix)
  local top_eq_str, bot_eq_str = get_equalizer_frames(info.status)

  -- Now Playing line
  local status_label
  if info.status == "buffering" then
    status_label = str_format("%s %s", get_spinner_frame(), STATUS_LABELS.buffering or "Buffering...")
  else
    status_label = STATUS_LABELS[info.status] or "Stopped"
  end
  local track_title = (info.title and info.title ~= "") and info.title or "Nenhuma música selecionada"
  local max_title_w = math_max(10, right_w - NUM_EQ_BARS - 14)
  local short_title = truncate_text(track_title, max_title_w)
  local now_playing_str = str_format("  %s: %s", status_label, short_title)
  local np_disp_w = str_displaywidth(now_playing_str)
  local pad_np = math_max(1, right_w - np_disp_w - NUM_EQ_BARS - 2)

  local line2_right_prefix = now_playing_str .. str_rep(" ", pad_np)
  local eq_top_start = #thumb_prefix + #line2_right_prefix
  local eq_top_end = eq_top_start + #top_eq_str
  local line2_right = line2_right_prefix .. top_eq_str .. "  "
  local rem_pad2 = math_max(0, right_w - str_displaywidth(line2_right))
  if rem_pad2 > 0 then
    line2_right = line2_right .. str_rep(" ", rem_pad2)
  end

  -- Progress bar line
  local cur_t = info.formatted_time or "00:00"
  local total_t = info.formatted_duration or "00:00"
  local pct_str = str_format("(%d%%)", math_floor(info.percent or 0))
  local time_labels_w = #cur_t + #total_t + #pct_str + 6
  local bar_w = math_max(6, right_w - time_labels_w - NUM_EQ_BARS - 6)
  local progress_bar_str = render_progress_bar(info.percent, bar_w)

  local before_bar = str_format("  %s  ", cur_t)
  local pb_start = #thumb_prefix + #before_bar
  local filled_count = math_floor((math_min(100, math_max(0, info.percent or 0)) / 100) * bar_w)
  local fill_bytes = filled_count * 3
  local empty_bytes = (bar_w - filled_count) * 3
  local pb_end = pb_start + fill_bytes + empty_bytes

  local prog_prefix = before_bar .. progress_bar_str .. str_format("  %s  %s", total_t, pct_str)
  local prog_disp_w = str_displaywidth(prog_prefix)
  local pad_prog = math_max(1, right_w - prog_disp_w - NUM_EQ_BARS - 2)

  local line3_right_prefix = prog_prefix .. str_rep(" ", pad_prog)
  local eq_bot_start = #thumb_prefix + #line3_right_prefix
  local eq_bot_end = eq_bot_start + #bot_eq_str
  local line3_right = line3_right_prefix .. bot_eq_str .. "  "
  local rem_pad3 = math_max(0, right_w - str_displaywidth(line3_right))
  if rem_pad3 > 0 then
    line3_right = line3_right .. str_rep(" ", rem_pad3)
  end

  local hl_data = {
    eq_top_start = eq_top_start,
    eq_top_end = eq_top_end,
    eq_bot_start = eq_bot_start,
    eq_bot_end = eq_bot_end,
    pb_start = pb_start,
    fill_bytes = fill_bytes,
    empty_bytes = empty_bytes,
    pb_end = pb_end,
  }

  return thumb_prefix .. line2_right, thumb_prefix .. line3_right, hl_data
end

-- Helper 3: Playlist list section rows
local function render_playlist_rows(visible_items, list_start, bottom_rows, width, cur_track_idx, is_playing, status)
  local rows = {}
  local row_item_map = {}
  local total = #visible_items

  for r = 1, bottom_rows do
    local v_idx = list_start + r - 1
    if v_idx <= total then
      local item = visible_items[v_idx]
      local row_str = ""
      if item.type == "folder" then
        local icon = item.is_expanded and " " or " "
        local prefix = str_format("  %s %s  (%d)", icon, item.name, item.count)
        row_str = prefix .. str_rep(" ", math_max(0, width - str_displaywidth(prefix)))
      else
        local track = item.track
        local title = track and track.title or "Sem título"
        local is_cur = (item.original_idx == cur_track_idx and is_playing)
        local icon
        if is_cur then
          if status == "buffering" then
            icon = get_spinner_frame() .. " "
          elseif status == "paused" then
            icon = "󰏤 "
          else
            icon = "󰐊 "
          end
        else
          icon = " "
        end
        local available_w = width - 10
        local prefix_title = str_format("    %s %s", icon, truncate_text(title, available_w))
        row_str = prefix_title .. str_rep(" ", math_max(0, width - str_displaywidth(prefix_title)))
      end
      table.insert(rows, row_str)
      table.insert(row_item_map, { line_idx = #rows, item_idx = v_idx, item = item })
    else
      table.insert(rows, cached_blank_line)
    end
  end

  return rows, row_item_map
end

-- Helper 4: Apply list and header highlights
local function apply_screen_highlights(lines, hl_data, tb_positions, toolbar_row_idx, row_item_map, width, cur_track_idx, is_playing, thumb_prefix_len, status)
  vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)

  -- Now playing status
  local np_line = lines[2] or ""
  local col_status_end = np_line:find(":", thumb_prefix_len + 1, true)
  if col_status_end then
    local hl = (status == "paused") and "MusicNvimPaused"
      or ((status == "buffering") and "MusicNvimBuffering" or "MusicNvimPlaying")
    vim.api.nvim_buf_add_highlight(buf, ns_id, hl, 1, thumb_prefix_len, col_status_end + 1)
  end

  -- Equalizers
  vim.api.nvim_buf_add_highlight(buf, ns_id, "MusicNvimEqualizer", 1, hl_data.eq_top_start, hl_data.eq_top_end)
  vim.api.nvim_buf_add_highlight(buf, ns_id, "MusicNvimEqualizer", 2, hl_data.eq_bot_start, hl_data.eq_bot_end)

  -- Progress bar
  if hl_data.fill_bytes > 0 then
    vim.api.nvim_buf_add_highlight(buf, ns_id, "MusicNvimProgressFill", 2, hl_data.pb_start, hl_data.pb_start + hl_data.fill_bytes)
  end
  if hl_data.empty_bytes > 0 then
    vim.api.nvim_buf_add_highlight(buf, ns_id, "MusicNvimProgressEmpty", 2, hl_data.pb_start + hl_data.fill_bytes, hl_data.pb_end)
  end

  -- Toolbar buttons
  for i, pos in ipairs(tb_positions) do
    local hl = (active_pane == "toolbar" and i == toolbar_idx) and "MusicNvimBtnActive" or "MusicNvimBtn"
    vim.api.nvim_buf_add_highlight(buf, ns_id, hl, toolbar_row_idx, pos.start_col, pos.end_col)
  end

  -- Bottom list items
  for _, map in ipairs(row_item_map) do
    local l_idx = map.line_idx - 1
    local item = map.item
    if active_pane == "list" and map.item_idx == selected_idx then
      vim.api.nvim_buf_set_extmark(buf, ns_id, l_idx, 0, {
        line_hl_group = "MusicNvimSelected",
        hl_group = "MusicNvimSelected",
        end_row = l_idx,
        end_col = width,
        hl_eol = true,
      })
    else
      if item.type == "folder" then
        vim.api.nvim_buf_add_highlight(buf, ns_id, "MusicNvimTitle", l_idx, 0, -1)
      elseif item.type == "track" and item.original_idx == cur_track_idx and is_playing then
        local hl = (status == "paused") and "MusicNvimPaused"
          or ((status == "buffering") and "MusicNvimBuffering" or "MusicNvimPlaying")
        vim.api.nvim_buf_add_highlight(buf, ns_id, hl, l_idx, 0, -1)
      end
    end
  end
end

-- Helper 5: Resolve track to show in thumbnail preview
local function resolve_target_track(visible_items)
  if active_pane == "list" and visible_items[selected_idx] then
    local item = visible_items[selected_idx]
    if item.type == "track" then
      return item.track
    elseif item.type == "folder" then
      return item.first_track or state.get_current_track()
    end
  end
  local cur = state.get_current_track()
  if cur then
    return cur
  end
  if visible_items[1] then
    local item = visible_items[1]
    return (item.type == "track") and item.track or item.first_track
  end
  return nil
end

-- Helper 6: Dispatch thumbnail according to layout
local function dispatch_thumbnail(geom, target_track)
  if is_opening_dialog or (help_win and vim.api.nvim_win_is_valid(help_win)) then
    preview.clear_image()
    return
  end
  if geom.layout == "embedded" and geom.has_thumb then
    update_thumbnail_image(geom, target_track)
  elseif geom.layout == "external" and geom.show_thumb_win then
    render_thumb_window(geom, target_track)
  else
    preview.clear_image()
    current_loaded_thumb_url = nil
    current_cached_thumb_png = nil
  end
end

render = function()
  if not M.is_open() or not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local geom = calc_size()
  local width = geom.width
  local height = geom.height
  local has_thumb = geom.has_thumb
  local right_w = geom.right_width or width
  local thumb_prefix = has_thumb and str_rep(" ", geom.thumb_total or 0) or ""

  local tb_line, tb_positions = get_toolbar_line(width, right_w, thumb_prefix)

  local info = mpv.get_playback_info()
  local playlist = state.get_playlist()
  local cur_track_idx = state.get_current_index()
  local is_playing = (info.status ~= "stopped")

  local fixed_rows = has_thumb and 7 or 6
  local bottom_rows = math_max(4, height - fixed_rows)
  local visible_items = build_visible_items(playlist)
  local total_items = #visible_items

  selected_idx = total_items > 0 and math_max(1, math_min(selected_idx, total_items)) or 1

  if total_items <= bottom_rows then
    list_start = 1
  else
    if selected_idx < list_start then
      list_start = selected_idx
    elseif selected_idx > list_start + bottom_rows - 1 then
      list_start = selected_idx - bottom_rows + 1
    end
    list_start = math_max(1, math_min(list_start, total_items - bottom_rows + 1))
  end

  local line2, line3, hl_data = render_header_section(info, right_w, thumb_prefix)
  local list_lines, row_item_map = render_playlist_rows(visible_items, list_start, bottom_rows, width, cur_track_idx, is_playing, info.status)

  local lines = {
    thumb_prefix .. str_rep(" ", right_w),
    line2,
    line3,
    thumb_prefix .. str_rep(" ", right_w),
    tb_line,
    thumb_prefix .. str_rep(" ", right_w),
  }
  if has_thumb then
    table.insert(lines, cached_blank_line)
  end
  local toolbar_row_idx = 4

  local header_count = #lines
  for _, r in ipairs(list_lines) do
    table.insert(lines, r)
  end
  for _, map in ipairs(row_item_map) do
    map.line_idx = header_count + map.line_idx
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  apply_screen_highlights(lines, hl_data, tb_positions, toolbar_row_idx, row_item_map, width, cur_track_idx, is_playing, #thumb_prefix, info.status)

  render_volume(geom, info)

  local target_track = resolve_target_track(visible_items)
  dispatch_thumbnail(geom, target_track)

  if info.status == "playing" or info.status == "buffering" then
    if not anim_timer then
      start_anim_timer()
    end
  else
    if anim_timer then
      stop_anim_timer()
    end
  end
end

local function open_help_dialog()
  if help_win and vim.api.nvim_win_is_valid(help_win) then
    return
  end

  is_opening_dialog = true
  preview.clear_image()

  local help_lines = {
    "",
    "  PLAYNVIM - Audio Player for Neovim",
    "  Clean & Minimalist MPV-Powered Media Player",
    "",
    "  Navigation & Controls:",
    "    h / l / <Left> / <Right>  Navigate toolbar buttons / collapse/expand folders",
    "    j / k / <Down> / <Up>     Navigate between toolbar and playlist",
    "    <Tab> / <S-Tab>          Switch focus between toolbar and playlist",
    "    <CR> / <Enter>           Execute selected button, folder or track",
    "    q / <Esc>                Close player window (audio continues playing)",
    "",
    "  Toolbar Buttons (top row):",
    "    󰑓  Restart current track from beginning",
    "    󰏤  Pause playback",
    "    󰐊  Resume / Play playback",
    "    +   Increase volume (+5%)",
    "    -   Decrease volume (-5%)",
    "    󰋖  Help dialog (this screen)",
    "",
    "  Press <Esc>, <CR> or 'q' to close",
    "",
  }

  local max_w = 70
  local dlg_h = #help_lines
  local dlg_col = math_floor((vim.o.columns - max_w) / 2)
  local dlg_row = math_floor((vim.o.lines - dlg_h) / 2)

  help_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = help_buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = help_buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = help_buf })

  local help_opts = {
    relative = "editor",
    row = dlg_row,
    col = dlg_col,
    width = max_w,
    height = dlg_h,
    border = "rounded",
    style = "minimal",
  }

  help_win = vim.api.nvim_open_win(help_buf, true, help_opts)
  vim.api.nvim_set_option_value(
    "winhighlight",
    "Normal:MusicNvimNormal,NormalFloat:MusicNvimNormal,FloatBorder:MusicNvimBorder,FloatTitle:MusicNvimTitle",
    { win = help_win }
  )

  vim.api.nvim_buf_set_lines(help_buf, 0, -1, false, help_lines)
  vim.api.nvim_buf_add_highlight(help_buf, ns_id, "MusicNvimTitle", 1, 0, -1)
  vim.api.nvim_buf_add_highlight(help_buf, ns_id, "MusicNvimNormal", 2, 0, -1)
  vim.api.nvim_buf_add_highlight(help_buf, ns_id, "MusicNvimTitle", 4, 0, -1)
  vim.api.nvim_buf_add_highlight(help_buf, ns_id, "MusicNvimTitle", 11, 0, -1)
  vim.api.nvim_buf_add_highlight(help_buf, ns_id, "MusicNvimNormal", #help_lines - 2, 0, -1)

  local function close_help()
    if help_win and vim.api.nvim_win_is_valid(help_win) then
      pcall(vim.api.nvim_win_close, help_win, true)
      help_win = nil
    end
    if help_buf and vim.api.nvim_buf_is_valid(help_buf) then
      pcall(vim.api.nvim_buf_delete, help_buf, { force = true })
      help_buf = nil
    end
    is_opening_dialog = false
    if M.is_open() then
      vim.api.nvim_set_current_win(win)
      render()
    end
  end

  vim.keymap.set("n", "<CR>", close_help, { buffer = help_buf, silent = true })
  vim.keymap.set("n", "<Esc>", close_help, { buffer = help_buf, silent = true })
  vim.keymap.set("n", "q", close_help, { buffer = help_buf, silent = true })
  vim.keymap.set("n", "<C-c>", close_help, { buffer = help_buf, silent = true })

  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = help_buf,
    callback = function()
      vim.schedule(close_help)
    end,
    once = true,
  })
end

local TOOLBAR_ACTIONS = {
  restart = function()
    mpv.seek(-999999)
  end,
  pause = function()
    mpv.pause()
  end,
  play = function()
    local info = mpv.get_playback_info()
    if info.status == "paused" then
      mpv.resume()
    elseif info.status == "stopped" then
      local cur = state.get_current_track()
      mpv.play(cur)
    else
      mpv.resume()
    end
  end,
  vol_up = function()
    mpv.volume_up(5)
  end,
  vol_dn = function()
    mpv.volume_down(5)
  end,
  help = function()
    open_help_dialog()
  end,
}

local function execute_toolbar_action()
  local opt = TOOLBAR_OPTIONS[toolbar_idx]
  if not opt then
    return
  end
  local action = TOOLBAR_ACTIONS[opt.id]
  if action then
    action()
    if opt.id ~= "help" then
      render()
    end
  end
end

function M.close()
  stop_anim_timer()
  mpv.remove_tick_listener(render)
  last_rendered_vol = -1
  last_rendered_vol_h = -1
  cached_geom = nil
  if resize_timer then
    resize_timer:stop()
    if not resize_timer:is_closing() then
      resize_timer:close()
    end
    resize_timer = nil
  end
  if resize_autocmd then
    pcall(vim.api.nvim_del_autocmd, resize_autocmd)
    resize_autocmd = nil
  end
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
    win = nil
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    buf = nil
  end
  if vol_win and vim.api.nvim_win_is_valid(vol_win) then
    pcall(vim.api.nvim_win_close, vol_win, true)
    vol_win = nil
  end
  if vol_buf and vim.api.nvim_buf_is_valid(vol_buf) then
    pcall(vim.api.nvim_buf_delete, vol_buf, { force = true })
    vol_buf = nil
  end
  preview.clear_image()
  current_loaded_thumb_url = nil
  current_cached_thumb_png = nil
  thumb_needs_draw = false
  if thumb_win and vim.api.nvim_win_is_valid(thumb_win) then
    pcall(vim.api.nvim_win_close, thumb_win, true)
    thumb_win = nil
  end
  if thumb_buf and vim.api.nvim_buf_is_valid(thumb_buf) then
    pcall(vim.api.nvim_buf_delete, thumb_buf, { force = true })
    thumb_buf = nil
  end
end

function M.open()
  if M.is_open() then
    vim.api.nvim_set_current_win(win)
    return
  end

  setup_highlights()

  local geom = calc_size()

  buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_set_option_value("filetype", "musicnvim", { buf = buf })

  local win_opts = {
    relative = "editor",
    row = geom.row,
    col = geom.col,
    width = geom.width,
    height = geom.height,
    border = config.opts.border or "rounded",
    style = "minimal",
  }

  win = vim.api.nvim_open_win(buf, true, win_opts)
  vim.api.nvim_set_option_value(
    "winhighlight",
    "Normal:MusicNvimNormal,NormalFloat:MusicNvimNormal,FloatBorder:MusicNvimBorder,FloatTitle:MusicNvimTitle,FloatFooter:MusicNvimNormal",
    { win = win }
  )
  vim.api.nvim_set_option_value("cursorline", false, { win = win })
  vim.api.nvim_set_option_value("wrap", false, { win = win })

  -- Janela externa de volume à direita
  vol_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = vol_buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = vol_buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = vol_buf })
  vim.api.nvim_set_option_value("filetype", "musicnvim_vol", { buf = vol_buf })

  local vol_win_opts = {
    relative = "editor",
    row = geom.row,
    col = geom.vol_col,
    width = geom.vol_width,
    height = geom.height,
    border = config.opts.border or "rounded",
    style = "minimal",
    focusable = false,
  }

  vol_win = vim.api.nvim_open_win(vol_buf, false, vol_win_opts)
  vim.api.nvim_set_option_value(
    "winhighlight",
    "Normal:MusicNvimNormal,NormalFloat:MusicNvimNormal,FloatBorder:MusicNvimBorder,FloatTitle:MusicNvimTitle,FloatFooter:MusicNvimNormal",
    { win = vol_win }
  )
  vim.api.nvim_set_option_value("cursorline", false, { win = vol_win })
  vim.api.nvim_set_option_value("wrap", false, { win = vol_win })

  -- Janela externa de miniatura à esquerda (Layout: external)
  if geom.show_thumb_win then
    thumb_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = thumb_buf })
    vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = thumb_buf })
    vim.api.nvim_set_option_value("swapfile", false, { buf = thumb_buf })
    vim.api.nvim_set_option_value("filetype", "musicnvim_thumb", { buf = thumb_buf })

    local thumb_win_opts = {
      relative = "editor",
      row = geom.row,
      col = geom.thumb_col,
      width = geom.thumb_width,
      height = geom.height,
      border = config.opts.border or "rounded",
      style = "minimal",
      focusable = false,
    }

    thumb_win = vim.api.nvim_open_win(thumb_buf, false, thumb_win_opts)
    vim.api.nvim_set_option_value(
      "winhighlight",
      "Normal:MusicNvimNormal,NormalFloat:MusicNvimNormal,FloatBorder:MusicNvimBorder,FloatTitle:MusicNvimTitle,FloatFooter:MusicNvimNormal",
      { win = thumb_win }
    )
    vim.api.nvim_set_option_value("cursorline", false, { win = thumb_win })
    vim.api.nvim_set_option_value("wrap", false, { win = thumb_win })
  end

  thumb_needs_draw = true

  local cur_idx = state.get_current_index()
  local playlist = state.get_playlist()
  preview.prefetch_playlist(playlist)

  local info = mpv.get_playback_info()
  if info.status ~= "stopped" then
    local cur_track = cur_idx and playlist[cur_idx]
    if cur_track and cur_track.playlist and expanded_folders[cur_track.playlist] == nil then
      set_folder_expanded(cur_track.playlist, true)
    end
  end

  local v_items = build_visible_items(playlist)
  if cur_idx and info.status ~= "stopped" then
    for v_i, item in ipairs(v_items) do
      if item.type == "track" and item.original_idx == cur_idx then
        selected_idx = v_i
        break
      end
    end
  else
    selected_idx = 1
  end

  -- Setup tick listener for live rendering
  mpv.start_polling()
  mpv.add_tick_listener(render)

  -- Keybindings for the floating window
  local map = function(lhs, rhs)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, silent = true, nowait = true })
  end

  map("q", M.close)
  map("<Esc>", M.close)
  map("<C-c>", M.close)

  -- Horizontal Navigation: h and l
  local function move_left()
    if active_pane == "toolbar" then
      toolbar_idx = ((toolbar_idx - 2 + #TOOLBAR_OPTIONS) % #TOOLBAR_OPTIONS) + 1
      render()
    else
      local cur_items = build_visible_items(state.get_playlist())
      local item = cur_items[selected_idx]
      if item and item.type == "folder" and item.is_expanded then
        set_folder_expanded(item.name, false)
        render()
      elseif item and item.type == "track" then
        set_folder_expanded(item.folder_name, false)
        local new_v = build_visible_items(state.get_playlist())
        for idx, v in ipairs(new_v) do
          if v.type == "folder" and v.name == item.folder_name then
            selected_idx = idx
            break
          end
        end
        render()
      else
        mpv.seek(-10)
      end
    end
  end

  local function move_right()
    if active_pane == "toolbar" then
      toolbar_idx = (toolbar_idx % #TOOLBAR_OPTIONS) + 1
      render()
    else
      local cur_items = build_visible_items(state.get_playlist())
      local item = cur_items[selected_idx]
      if item and item.type == "folder" and not item.is_expanded then
        set_folder_expanded(item.name, true)
        render()
      else
        mpv.seek(10)
      end
    end
  end

  map("h", move_left)
  map("<Left>", move_left)
  map("l", move_right)
  map("<Right>", move_right)

  -- Vertical Navigation: j and k
  local function move_down()
    local cur_items = build_visible_items(state.get_playlist())
    if active_pane == "toolbar" then
      active_pane = "list"
      selected_idx = 1
      render()
    else
      local total = #cur_items
      selected_idx = math_min(total, selected_idx + 1)
      render()
    end
  end

  local function move_up()
    if active_pane == "list" then
      if selected_idx > 1 then
        selected_idx = selected_idx - 1
        render()
      else
        active_pane = "toolbar"
        toolbar_idx = 3 -- foca no 󰐊 Player no centro
        render()
      end
    else
      render()
    end
  end

  map("j", move_down)
  map("<Down>", move_down)
  map("k", move_up)
  map("<Up>", move_up)

  -- Tab to toggle pane between toolbar and list
  map("<Tab>", function()
    active_pane = (active_pane == "toolbar") and "list" or "toolbar"
    render()
  end)
  map("<S-Tab>", function()
    active_pane = (active_pane == "toolbar") and "list" or "toolbar"
    render()
  end)

  -- Action: <CR> / <Enter>
  map("<CR>", function()
    if active_pane == "toolbar" then
      execute_toolbar_action()
    else
      local cur_items = build_visible_items(state.get_playlist())
      local item = cur_items[selected_idx]
      if item then
        if item.type == "folder" then
          toggle_folder(item.name)
          render()
        elseif item.type == "track" then
          state.set_current_index(item.original_idx)
          mpv.play(state.get_current_track())
        end
      end
    end
  end)



  -- Handle dynamic terminal resizing and focus changes
  local function handle_terminal_resize()
    if not M.is_open() then
      return
    end
    preview.invalidate_tmux_offset()
    M.reconfigure_layout()

    -- Follow-up debounced check to guarantee correct placement after terminal reflow and font changes
    if resize_timer then
      resize_timer:stop()
    else
      resize_timer = uv.new_timer()
    end
    resize_timer:start(60, 0, vim.schedule_wrap(function()
      if M.is_open() then
        preview.invalidate_tmux_offset()
        M.reconfigure_layout()
      end
      if resize_timer and not resize_timer:is_closing() then
        resize_timer:close()
      end
      resize_timer = nil
    end))
  end

  resize_autocmd = vim.api.nvim_create_autocmd({ "VimResized", "FocusGained" }, {
    callback = handle_terminal_resize,
  })

  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    callback = function()
      if is_opening_dialog then
        return
      end
      vim.schedule(function()
        if is_opening_dialog or (help_win and vim.api.nvim_win_is_valid(help_win)) then
          return
        end
        local cur_win = vim.api.nvim_get_current_win()
        if cur_win ~= win and cur_win ~= vol_win and (not thumb_win or cur_win ~= thumb_win) then
          M.close()
        end
      end)
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    callback = function()
      M.close()
    end,
    once = true,
  })

  render()
end

function M.reconfigure_layout()
  if not M.is_open() then
    return
  end
  preview.invalidate_tmux_offset()
  preview.clear_image()
  current_loaded_thumb_url = nil
  current_cached_thumb_png = nil
  thumb_needs_draw = true
  cached_geom = nil
  cached_tb_width = -1
  cached_tb_has_thumb = nil

  local g = calc_size()

  pcall(vim.api.nvim_win_set_config, win, {
    relative = "editor",
    row = g.row,
    col = g.col,
    width = g.width,
    height = g.height,
  })

  if vol_win and vim.api.nvim_win_is_valid(vol_win) then
    pcall(vim.api.nvim_win_set_config, vol_win, {
      relative = "editor",
      row = g.row,
      col = g.vol_col,
      width = g.vol_width,
      height = g.height,
    })
  end

  if g.show_thumb_win then
    if thumb_win and vim.api.nvim_win_is_valid(thumb_win) then
      pcall(vim.api.nvim_win_set_config, thumb_win, {
        relative = "editor",
        row = g.row,
        col = g.thumb_col,
        width = g.thumb_width,
        height = g.height,
      })
    else
      if not thumb_buf or not vim.api.nvim_buf_is_valid(thumb_buf) then
        thumb_buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_set_option_value("buftype", "nofile", { buf = thumb_buf })
        vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = thumb_buf })
        vim.api.nvim_set_option_value("swapfile", false, { buf = thumb_buf })
        vim.api.nvim_set_option_value("filetype", "musicnvim_thumb", { buf = thumb_buf })
      end

      local thumb_win_opts = {
        relative = "editor",
        row = g.row,
        col = g.thumb_col,
        width = g.thumb_width,
        height = g.height,
        border = config.opts.border or "rounded",
        style = "minimal",
        focusable = false,
      }

      thumb_win = vim.api.nvim_open_win(thumb_buf, false, thumb_win_opts)
      vim.api.nvim_set_option_value(
        "winhighlight",
        "Normal:MusicNvimNormal,NormalFloat:MusicNvimNormal,FloatBorder:MusicNvimBorder,FloatTitle:MusicNvimTitle,FloatFooter:MusicNvimNormal",
        { win = thumb_win }
      )
      vim.api.nvim_set_option_value("cursorline", false, { win = thumb_win })
      vim.api.nvim_set_option_value("wrap", false, { win = thumb_win })
    end
  else
    if thumb_win and vim.api.nvim_win_is_valid(thumb_win) then
      pcall(vim.api.nvim_win_close, thumb_win, true)
      thumb_win = nil
    end
    if thumb_buf and vim.api.nvim_buf_is_valid(thumb_buf) then
      pcall(vim.api.nvim_buf_delete, thumb_buf, { force = true })
      thumb_buf = nil
    end
  end

  render()
end

local LAYOUT_CYCLE = {
  embedded = "classic",
  classic = "external",
  external = "embedded",
}

function M.get_layout()
  return get_layout()
end

function M.cycle_layout()
  local cur = get_layout()
  local nxt = LAYOUT_CYCLE[cur] or "embedded"
  M.set_layout(nxt)
end

function M.set_layout(new_layout)
  local norm = LAYOUT_NAMES[string.lower(tostring(new_layout or ""))]
  if not norm then
    vim.notify("PlayNvim: Layout inválido '" .. tostring(new_layout) .. "'. Opções: classic, external, embedded", vim.log.levels.WARN)
    return
  end
  current_layout = norm
  if M.is_open() then
    M.reconfigure_layout()
  end
  local labels = {
    classic = "Clássico (sem thumbnail)",
    external = "Janela Externa (thumbnail à esquerda)",
    embedded = "Embutido (thumbnail no topo esquerdo)",
  }
  vim.notify("PlayNvim Layout: " .. (labels[norm] or norm), vim.log.levels.INFO)
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

return M
