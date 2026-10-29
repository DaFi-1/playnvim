local M = {}

local ffi = require("ffi")
local uv = vim.uv or vim.loop

-- FFI C declarations for sqlite3
ffi.cdef[[
  typedef struct sqlite3 sqlite3;
  typedef struct sqlite3_stmt sqlite3_stmt;

  int sqlite3_open(const char *filename, sqlite3 **ppDb);
  int sqlite3_close(sqlite3 *db);
  int sqlite3_exec(sqlite3 *db, const char *sql, int (*callback)(void*,int,char**,char**), void *arg, char **errmsg);
  void sqlite3_free(void *p);

  int sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte, sqlite3_stmt **ppStmt, const char **pzTail);
  int sqlite3_step(sqlite3_stmt *pStmt);
  int sqlite3_finalize(sqlite3_stmt *pStmt);
  int sqlite3_bind_text(sqlite3_stmt *pStmt, int idx, const char *val, int len, void(*destructor)(void*));
  int sqlite3_bind_int64(sqlite3_stmt *pStmt, int idx, int64_t val);
  const unsigned char *sqlite3_column_text(sqlite3_stmt *pStmt, int iCol);
]]

local SQLITE_OK = 0
local SQLITE_ROW = 100
local SQLITE_DONE = 101
local SQLITE_TRANSIENT = ffi.cast("void(*)(void*)", -1)

local lib = nil
local db_handle = nil
local mem_cache = {}
local is_initialized = false
local db_file_path = nil

local lib_checked = false

local function load_sqlite_lib()
  if lib_checked then
    return lib
  end
  lib_checked = true
  local lib_names = {
    "libsqlite3.so.0",
    "libsqlite3.so",
    "sqlite3",
    "libsqlite3.dylib",
  }
  for _, name in ipairs(lib_names) do
    local ok, res = pcall(ffi.load, name)
    if ok and res then
      lib = res
      return lib
    end
  end
  return nil
end

function M.get_db_path()
  if db_file_path then
    return db_file_path
  end

  local info = debug.getinfo(1, "S")
  local source = info and info.source or ""
  local plugin_root = nil
  if source:sub(1, 1) == "@" then
    local file_path = source:sub(2)
    -- lua/playnvim/db.lua -> 3 levels up -> plugin root
    plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(file_path)))
  end

  local data_dir = nil
  if plugin_root and uv.fs_stat(plugin_root) then
    data_dir = vim.fn.fnamemodify(plugin_root .. "/data", ":p"):gsub("/+$", "")
  else
    data_dir = vim.fn.stdpath("data") .. "/playnvim"
  end

  pcall(vim.fn.mkdir, data_dir, "p")
  pcall(vim.fn.mkdir, data_dir .. "/covers", "p")

  db_file_path = data_dir .. "/thumbnails.db"
  return db_file_path
end

function M.get_covers_dir()
  local path = M.get_db_path()
  local dir = vim.fs.dirname(path) .. "/covers"
  pcall(vim.fn.mkdir, dir, "p")
  return dir
end

function M.init()
  if is_initialized then
    return true
  end

  local path = M.get_db_path()
  local sqlite_lib = load_sqlite_lib()

  if sqlite_lib then
    local db_ptr = ffi.new("sqlite3*[1]")
    local rc = sqlite_lib.sqlite3_open(path, db_ptr)
    if rc == SQLITE_OK then
      db_handle = db_ptr[0]
      local errmsg = ffi.new("char*[1]")
      local schema = [[
        CREATE TABLE IF NOT EXISTS thumbnails (
          url TEXT PRIMARY KEY,
          video_id TEXT,
          title TEXT,
          image_path TEXT,
          created_at INTEGER
        );
      ]]
      sqlite_lib.sqlite3_exec(db_handle, schema, nil, nil, errmsg)
      if errmsg[0] ~= nil then
        sqlite_lib.sqlite3_free(errmsg[0])
      end

      -- Pre-load in-memory cache
      local stmt_ptr = ffi.new("sqlite3_stmt*[1]")
      local q = "SELECT url, video_id, title, image_path FROM thumbnails;"
      if sqlite_lib.sqlite3_prepare_v2(db_handle, q, -1, stmt_ptr, nil) == SQLITE_OK then
        local stmt = stmt_ptr[0]
        while sqlite_lib.sqlite3_step(stmt) == SQLITE_ROW do
          local u = ffi.string(sqlite_lib.sqlite3_column_text(stmt, 0))
          local vid = ffi.string(sqlite_lib.sqlite3_column_text(stmt, 1))
          local t = ffi.string(sqlite_lib.sqlite3_column_text(stmt, 2))
          local img = ffi.string(sqlite_lib.sqlite3_column_text(stmt, 3))
          if u and img and uv.fs_stat(img) then
            mem_cache[u] = {
              video_id = vid,
              title = t,
              image_path = img,
            }
          end
        end
        sqlite_lib.sqlite3_finalize(stmt)
      end

      is_initialized = true
      return true
    end
  end

  -- CLI fallback if libsqlite3 cannot be loaded via FFI
  if vim.fn.executable("sqlite3") == 1 then
    local schema = "CREATE TABLE IF NOT EXISTS thumbnails (url TEXT PRIMARY KEY, video_id TEXT, title TEXT, image_path TEXT, created_at INTEGER);"
    vim.fn.system({ "sqlite3", path, schema })
    local out = vim.fn.system({ "sqlite3", "-separator", "\t", path, "SELECT url, video_id, title, image_path FROM thumbnails;" })
    if type(out) == "string" then
      for line in out:gmatch("[^\r\n]+") do
        local parts = vim.split(line, "\t")
        if #parts >= 4 and parts[1] and parts[4] and uv.fs_stat(parts[4]) then
          mem_cache[parts[1]] = {
            video_id = parts[2],
            title = parts[3],
            image_path = parts[4],
          }
        end
      end
    end
    is_initialized = true
    return true
  end

  return false
end

function M.get(url)
  if not url or url == "" then
    return nil
  end
  if not is_initialized then
    M.init()
  end

  local cached = mem_cache[url]
  if cached then
    if cached.verified or (cached.image_path and uv.fs_stat(cached.image_path)) then
      cached.verified = true
      return cached.image_path
    end
    mem_cache[url] = nil
  end

  if db_handle and lib then
    local stmt_ptr = ffi.new("sqlite3_stmt*[1]")
    local sql = "SELECT video_id, title, image_path FROM thumbnails WHERE url = ? LIMIT 1;"
    if lib.sqlite3_prepare_v2(db_handle, sql, -1, stmt_ptr, nil) == SQLITE_OK then
      local stmt = stmt_ptr[0]
      lib.sqlite3_bind_text(stmt, 1, url, -1, SQLITE_TRANSIENT)
      local rc = lib.sqlite3_step(stmt)
      local res = nil
      if rc == SQLITE_ROW then
        local vid = ffi.string(lib.sqlite3_column_text(stmt, 0))
        local tit = ffi.string(lib.sqlite3_column_text(stmt, 1))
        local img = ffi.string(lib.sqlite3_column_text(stmt, 2))
        if img and uv.fs_stat(img) then
          mem_cache[url] = { video_id = vid, title = tit, image_path = img, verified = true }
          res = img
        end
      end
      lib.sqlite3_finalize(stmt)
      return res
    end
  end

  return nil
end

function M.set(url, video_id, title, image_path)
  if not url or not image_path or not uv.fs_stat(image_path) then
    return false
  end
  if not is_initialized then
    M.init()
  end

  mem_cache[url] = {
    video_id = video_id or "",
    title = title or "",
    image_path = image_path,
    verified = true,
  }

  if db_handle and lib then
    local stmt_ptr = ffi.new("sqlite3_stmt*[1]")
    local sql = "INSERT OR REPLACE INTO thumbnails (url, video_id, title, image_path, created_at) VALUES (?, ?, ?, ?, ?);"
    if lib.sqlite3_prepare_v2(db_handle, sql, -1, stmt_ptr, nil) == SQLITE_OK then
      local stmt = stmt_ptr[0]
      lib.sqlite3_bind_text(stmt, 1, url, -1, SQLITE_TRANSIENT)
      lib.sqlite3_bind_text(stmt, 2, video_id or "", -1, SQLITE_TRANSIENT)
      lib.sqlite3_bind_text(stmt, 3, title or "", -1, SQLITE_TRANSIENT)
      lib.sqlite3_bind_text(stmt, 4, image_path, -1, SQLITE_TRANSIENT)
      lib.sqlite3_bind_int64(stmt, 5, os.time())
      lib.sqlite3_step(stmt)
      lib.sqlite3_finalize(stmt)
      return true
    end
  end

  if vim.fn.executable("sqlite3") == 1 then
    local path = M.get_db_path()
    local function sql_quote(val)
      if not val then
        return "''"
      end
      return "'" .. tostring(val):gsub("'", "''") .. "'"
    end
    local sql = string.format(
      "INSERT OR REPLACE INTO thumbnails (url, video_id, title, image_path, created_at) VALUES (%s, %s, %s, %s, %d);",
      sql_quote(url),
      sql_quote(video_id),
      sql_quote(title),
      sql_quote(image_path),
      os.time()
    )
    vim.fn.system({ "sqlite3", path, sql })
    return true
  end

  return false
end

function M.close()
  if db_handle and lib then
    lib.sqlite3_close(db_handle)
    db_handle = nil
    is_initialized = false
  end
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    M.close()
  end,
})

return M
