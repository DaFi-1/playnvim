local db = require("playnvim.db")

local M = {}

local uv = vim.uv or vim.loop
local IMAGE_ID_BASE = 88200
local current_image_id = IMAGE_ID_BASE

local function next_image_id()
  current_image_id = current_image_id + 1
  if current_image_id > 88300 then
    current_image_id = IMAGE_ID_BASE
  end
  return current_image_id
end

local last_displayed_url = nil
local last_drawn = {
  path = nil,
  win = nil,
  term_row = -1,
  term_col = -1,
  cols = -1,
  rows = -1,
}

local b64_cache = {}

local function is_in_tmux()
  return vim.env.TMUX ~= nil or (vim.env.TERM_PROGRAM == "tmux")
end

local tmux_offset_left = 0
local tmux_offset_top = 0
local tmux_pane_width = 80
local tmux_pane_height = 24
local last_tmux_query = 0
local last_editor_cols = -1
local last_editor_lines = -1

function M.invalidate_tmux_offset()
  last_tmux_query = 0
  last_editor_cols = -1
  last_editor_lines = -1
end

local function get_tmux_pane_offset()
  if not is_in_tmux() then
    return 0, 0, vim.o.columns, vim.o.lines
  end
  local cols = vim.o.columns
  local lines = vim.o.lines
  if cols == last_editor_cols and lines == last_editor_lines and last_tmux_query > 0 then
    return tmux_offset_left, tmux_offset_top, tmux_pane_width, tmux_pane_height
  end
  last_editor_cols = cols
  last_editor_lines = lines
  last_tmux_query = uv.now()

  local target_flag = ""
  if vim.env.TMUX_PANE and vim.env.TMUX_PANE ~= "" then
    target_flag = string.format("-t '%s' ", vim.env.TMUX_PANE)
  end
  local cmd = string.format("tmux display-message -p %s'#{pane_left},#{pane_top},#{pane_width},#{pane_height}' 2>/dev/null", target_flag)
  local handle = io.popen(cmd)
  if handle then
    local res = handle:read("*a")
    handle:close()
    if res then
      local pl, pt, pw, ph = res:match("(%d+),(%d+),(%d+),(%d+)")
      if pl and pt then
        tmux_offset_left = tonumber(pl) or 0
        tmux_offset_top = tonumber(pt) or 0
        tmux_pane_width = tonumber(pw) or cols
        tmux_pane_height = tonumber(ph) or lines
      end
    end
  end
  return tmux_offset_left, tmux_offset_top, tmux_pane_width, tmux_pane_height
end

local function wrap_tmux(seq)
  if is_in_tmux() then
    return "\x1bPtmux;" .. seq:gsub("\x1b", "\x1b\x1b") .. "\x1b\\"
  end
  return seq
end

function M.extract_video_id(url)
  if not url or type(url) ~= "string" then
    return nil
  end
  local id = url:match("[?&]v=([%w_%-]+)")
  if not id then
    id = url:match("youtu%.be/([%w_%-]+)")
  end
  if not id then
    id = url:match("youtube%.com/embed/([%w_%-]+)")
  end
  if not id then
    id = url:match("youtube%.com/v/([%w_%-]+)")
  end
  return id
end

function M.clear_image()
  local del_seq = "\x1b_Ga=d,d=a,q=2\x1b\\"
  pcall(vim.api.nvim_chan_send, vim.v.stderr, wrap_tmux(del_seq))
  last_displayed_url = nil
  last_drawn.path = nil
  last_drawn.win = nil
  last_drawn.term_row = -1
  last_drawn.term_col = -1
  last_drawn.cols = -1
  last_drawn.rows = -1
end

local active_downloads = {}

local function handle_download_result(res, png_path, url, vid_id, title)
  vim.schedule(function()
    local ok = (res.code == 0 and uv.fs_stat(png_path))
    local final_path = ok and png_path or nil
    if ok then
      db.set(url, vid_id, title, png_path)
    end
    local cbs = active_downloads[url] or {}
    active_downloads[url] = nil
    for _, cb in ipairs(cbs) do
      cb(final_path)
    end
  end)
end

function M.get_thumbnail(track, callback)
  if not track or not track.url or track.url == "" then
    if callback then
      callback(nil)
    end
    return
  end

  local url = track.url

  -- Fast path 1: Check SQLite database / in-memory cache
  local cached_db = db.get(url)
  if cached_db then
    if callback then
      callback(cached_db)
    end
    return
  end

  local covers_dir = db.get_covers_dir()
  local vid_id = M.extract_video_id(url)
  local file_hash = vid_id or vim.fn.sha256(url):sub(1, 16)
  local png_path = covers_dir .. "/" .. file_hash .. ".png"

  -- Fast path 2: Check covers directory on disk
  if uv.fs_stat(png_path) then
    db.set(url, vid_id, track.title, png_path)
    if callback then
      callback(png_path)
    end
    return
  end

  -- In-flight deduplication: prevent redundant parallel downloads for the same URL
  if active_downloads[url] then
    if callback then
      table.insert(active_downloads[url], callback)
    end
    return
  end
  active_downloads[url] = callback and { callback } or {}

  if vim.fn.executable("ffmpeg") ~= 1 then
    local cbs = active_downloads[url] or {}
    active_downloads[url] = nil
    for _, cb in ipairs(cbs) do
      cb(nil)
    end
    return
  end

  -- YouTube fast path with ffmpeg
  if vid_id then
    local yt_img_url = "https://img.youtube.com/vi/" .. vid_id .. "/hqdefault.jpg"
    vim.system(
      { "ffmpeg", "-y", "-i", yt_img_url, "-vf", "scale=360:-1", "-update", "1", "-frames:v", "1", png_path },
      { timeout = 10000 },
      function(res)
        handle_download_result(res, png_path, url, vid_id, track.title)
      end
    )
    return
  end

  if vim.fn.executable("yt-dlp") ~= 1 then
    local cbs = active_downloads[url] or {}
    active_downloads[url] = nil
    for _, cb in ipairs(cbs) do
      cb(nil)
    end
    return
  end

  -- Fallback with yt-dlp for other streaming sites
  vim.system(
    { "yt-dlp", "--get-thumbnail", url },
    { timeout = 15000 },
    function(yres)
      if yres.code == 0 and yres.stdout and #yres.stdout > 0 then
        local thumb_url = vim.trim(yres.stdout)
        if thumb_url:find("^http") then
          vim.system(
            { "ffmpeg", "-y", "-i", thumb_url, "-vf", "scale=360:-1", "-update", "1", "-frames:v", "1", png_path },
            { timeout = 10000 },
            function(fres)
              handle_download_result(fres, png_path, url, vid_id, track.title)
            end
          )
          return
        end
      end
      vim.schedule(function()
        local cbs = active_downloads[url] or {}
        active_downloads[url] = nil
        for _, cb in ipairs(cbs) do
          cb(nil)
        end
      end)
    end
  )
end

-- Pre-download all covers in background on initialization
function M.prefetch_playlist(playlist, on_complete)
  if not playlist or #playlist == 0 then
    if on_complete then
      on_complete()
    end
    return
  end

  db.init()
  local total = #playlist
  local completed = 0

  local function step()
    completed = completed + 1
    if completed >= total and on_complete then
      vim.schedule(on_complete)
    end
  end

  for _, track in ipairs(playlist) do
    if track and track.url and track.url ~= "" then
      local cached = db.get(track.url)
      if cached and uv.fs_stat(cached) then
        step()
      else
        M.get_thumbnail(track, function(_)
          step()
        end)
      end
    else
      step()
    end
  end
end

function M.render_image(win, png_path, row_offset, col_offset, max_w, max_h, force)
  if not win or not vim.api.nvim_win_is_valid(win) or not png_path then
    M.clear_image()
    return
  end

  local ok, pos = pcall(vim.api.nvim_win_get_position, win)
  if not ok or not pos then
    M.clear_image()
    return
  end

  local win_row, win_col = pos[1], pos[2]
  local win_w = vim.api.nvim_win_get_width(win)
  local win_h = vim.api.nvim_win_get_height(win)

  row_offset = row_offset or 1
  col_offset = col_offset or 1
  local img_cols = max_w or (win_w - (col_offset * 2))
  local img_rows = max_h or (win_h - (row_offset * 2))

  local pane_left, pane_top, pane_width, pane_height = get_tmux_pane_offset()

  -- In Neovim 0-indexed coords + 1 for border + 1 for 1-indexed terminal
  local term_row = win_row + 1 + row_offset + pane_top
  local term_col = win_col + 1 + col_offset + pane_left

  -- Determine strict boundaries for Neovim's pane in terminal screen
  local max_allowed_col = pane_left + pane_width
  local max_allowed_row = pane_top + pane_height

  -- Also restrict to floating window boundaries
  local max_win_cols = win_w - col_offset
  local max_win_rows = win_h - row_offset

  -- Clamp image columns to pane and window bounds
  local avail_cols = max_allowed_col - term_col + 1
  img_cols = math.min(img_cols, avail_cols, max_win_cols)

  -- Clamp image rows to pane and window bounds
  local avail_rows = max_allowed_row - term_row + 1
  img_rows = math.min(img_rows, avail_rows, max_win_rows)

  -- If image does not fit cleanly or starts outside bounds, purge image and bail out
  if img_cols < 4 or img_rows < 3
    or term_row < (pane_top + 1) or term_col < (pane_left + 1)
    or term_row > max_allowed_row or term_col > max_allowed_col
  then
    M.clear_image()
    return
  end

  -- O(1) Geometry stability guard:
  -- If nothing moved or changed, return immediately to prevent redundant terminal I/O and flicker
  if not force
    and last_drawn.path == png_path
    and last_drawn.win == win
    and last_drawn.term_row == term_row
    and last_drawn.term_col == term_col
    and last_drawn.cols == img_cols
    and last_drawn.rows == img_rows
  then
    return
  end

  if not uv.fs_stat(png_path) then
    M.clear_image()
    return
  end

  last_drawn.path = png_path
  last_drawn.win = win
  last_drawn.term_row = term_row
  last_drawn.term_col = term_col
  last_drawn.cols = img_cols
  last_drawn.rows = img_rows

  local img_id = next_image_id()
  local b64_path = b64_cache[png_path]
  if not b64_path then
    b64_path = vim.base64.encode(png_path)
    b64_cache[png_path] = b64_path
  end

  -- Use ESC 7 (DECSC) and ESC 8 (DECRC) for universal cursor save & restore,
  -- and clear previous images (d=a) to prevent ghosting or displacement artifacts
  local raw_seq = string.format(
    "\x1b7\x1b_Ga=d,d=a,q=2\x1b\\\x1b[%d;%dH\x1b_Ga=T,f=100,t=f,c=%d,r=%d,i=%d,C=1,q=2;%s\x1b\\\x1b8",
    term_row, term_col, img_cols, img_rows, img_id, b64_path
  )

  pcall(vim.api.nvim_chan_send, vim.v.stderr, wrap_tmux(raw_seq))
  last_displayed_url = png_path
end

return M
