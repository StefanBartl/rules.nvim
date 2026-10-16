---@module 'rules.engine.waivers'
---@brief Load a repo's `.rules-waivers.json`: consciously accepted findings
--- that shouldn't re-flag on every run.
---@description
--- A waiver never turns a failing rule into a silent pass — it turns it into a distinct "waived"
--- status that still shows in the buffer report with its reason and is
--- excluded from the quickfix worklist, but stays visible. That is the
--- difference between waiving a finding and deleting the rule: the record
--- of "this was seen and consciously accepted" survives.
---
--- The file maps a rule id to a waiver, in one of two forms that may be mixed in one file:
---
---   { "DEP-01": "reason" }                                         -- no expiry, every path
---   { "DEP-02": { "reason": "...", "expires": "2026-12-31", "paths": ["src/legacy", "docs/**/*.md"] } }
---
--- `expires` is a calendar date (`YYYY-MM-DD`, no time zone). A waiver is valid through that day; the day after, it is
--- EXPIRED: the finding flags again and the report says so. `paths` (relative to the project root, `/`, no `..`) limit
--- the waiver to findings in those files or folders; a glob (`*`, `**`, `?`, `[ab]`, `{a,b}`) is matched on the whole
--- path (`vim.glob`), a plain name is that file or the folder with that name (a name with glob characters, `pages/[id].tsx`,
--- is also taken as written).
---
--- Strictness is the point: a file that exists but cannot be used (unknown key, bad date, bad path, wrong type) is an
--- error, never "no waivers". `M.load` keeps its old shape for existing callers (id -> reason text); `M.load_entries`
--- gives the full entry (`reason`, `expires?`, `paths?`).

-- ERR-05/06: `lib.lua.error.safe_call` instead of a hand-rolled `pcall`.
local safe_error = require("lib.lua.error")

local M = {}

---@class Rules.Waiver
---@field reason string
---@field expires? string  `YYYY-MM-DD`: valid through that day
---@field paths? string[]  files, folders or globs relative to the project root

---@alias Rules.Waivers table<string, string>
---@alias Rules.WaiverEntries table<string, Rules.Waiver>

--- The file name at the project root.
M.FILE = ".rules-waivers.json"

-- SEC-33: re-validate every field of a persisted snapshot on load -- type,
-- length AND count cap. `report/buffer.lua` renders a reason via
-- `nvim_buf_set_lines`, which rejects a string containing a newline, so a
-- multi-line reason (legal JSON, a natural shape for "ticket + explanation")
-- would otherwise crash every `:Rules check`/`gate` run in the repo at
-- render time instead of at load time.
M.MAX_REASON_LEN = 500
M.MAX_WAIVERS = 500
M.MAX_PATHS = 50
M.MAX_PATH_LEN = 200
M.MAX_ID_LEN = 100

local KEYS = { "expires", "paths", "reason" }

--- Paths that differ only in case are one folder on Windows and (by default) on macOS.
local CASE_INSENSITIVE = vim.fn.has("win32") == 1 or vim.fn.has("mac") == 1

-- ── dates and the clock ─────────────────────────────────────────────────────────

--- Whether `date` is a real calendar date in the form `YYYY-MM-DD` (leap years counted, no time, no time zone).
---@param date any
---@return boolean
function M.valid_date(date)
  if type(date) ~= "string" then
    return false
  end
  local y, m, d = date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not y then
    return false
  end
  local year, month, day = tonumber(y), tonumber(m), tonumber(d)
  if year < 1 or month < 1 or month > 12 or day < 1 then
    return false
  end
  local leap = (year % 4 == 0 and year % 100 ~= 0) or year % 400 == 0
  local days = { 31, leap and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  return day <= days[month]
end

--- The clock of the engine: today's calendar date on the machine that runs the check. A seam: a spec replaces it, so
--- nothing depends on the real date.
---@return string
function M.clock()
  return os.date("%Y-%m-%d") --[[@as string]]
end

--- The date a run counts as today: the one given (`opts.today`, for reproducible runs and specs), else the clock.
---@param given any
---@return string|nil today
---@return string|nil err
function M.today(given)
  if given == nil then
    return M.clock(), nil
  end
  if not M.valid_date(given) then
    return nil, "today must be a calendar date in the form YYYY-MM-DD"
  end
  return given, nil
end

--- Whether a waiver is expired on `today`: its last day is before it (a waiver is valid through its `expires` day).
---@param entry Rules.Waiver
---@param today string
---@return boolean
function M.is_expired(entry, today)
  return entry.expires ~= nil and entry.expires < today
end

-- ── validation ──────────────────────────────────────────────────────────────────

--- The length of a text in characters (the limits below are told in characters, not bytes: a 300-letter German reason is
--- 300 characters, not 600). Bytes that are no UTF-8 count one each.
---@param text string
---@return integer
local function chars(text)
  return vim.fn.strchars(text)
end

--- Why a reason cannot be used, or nil.
---@param reason any
---@return string|nil why
function M.reason_error(reason)
  if type(reason) ~= "string" then
    return "must be a text"
  end
  if reason:find("\n", 1, true) then
    return "must not contain a newline (it is rendered as one report line)"
  end
  if reason:find("[%z\1-\8\11-\31\127]") then
    return "must not contain a control character"
  end
  if chars(reason) > M.MAX_REASON_LEN then
    return ("exceeds %d characters"):format(M.MAX_REASON_LEN)
  end
  return nil
end

--- Whether a glob or name is a valid `paths` entry's pattern.
---@param pattern string
---@return boolean
local function glob_ok(pattern)
  local ok = pcall(vim.glob.to_lpeg, pattern)
  return ok
end

--- Whether a path entry has a glob character.
---@param path string
---@return boolean
local function has_glob(path)
  return path:find("[%*%?%[%]{}]") ~= nil
end

--- Why one `paths` entry cannot be used, or nil: relative to the project root, `/` only, no `..`, no absolute path.
---@param path any
---@return string|nil why
function M.path_error(path)
  if type(path) ~= "string" or path == "" then
    return "a path must be a non-empty text"
  end
  if chars(path) > M.MAX_PATH_LEN then
    return ("a path exceeds %d characters"):format(M.MAX_PATH_LEN)
  end
  if path:find("[%z\1-\31\127]") then
    return "a path must not contain a control character"
  end
  if path:find("\\", 1, true) then
    return "a path uses / (a backslash is not a separator)"
  end
  if path:sub(1, 1) == "/" or path:match("^%a:") or path:sub(1, 1) == "~" then
    return "a path is relative to the project root, not absolute"
  end
  local body = path:gsub("/$", "")
  if body == "" then
    return "a path must name something"
  end
  for segment in (body .. "/"):gmatch("(.-)/") do
    if segment == ".." then
      return "a path must not contain .. (it stays inside the project)"
    end
    if segment == "." or segment == "" then
      return "a path must not contain an empty or . segment"
    end
  end
  if has_glob(body) and not glob_ok(body) then
    return "a path is not a valid glob"
  end
  return nil
end

--- Why a `paths` list cannot be used, or nil: a non-empty list of valid, distinct paths.
---@param paths any
---@return string|nil why
function M.paths_error(paths)
  if type(paths) ~= "table" or not vim.islist(paths) then
    return "paths must be a list of text"
  end
  if #paths == 0 then
    return "paths must not be empty (leave it out for every path)"
  end
  if #paths > M.MAX_PATHS then
    return ("paths has more than %d entries"):format(M.MAX_PATHS)
  end
  local seen = {}
  for _, path in ipairs(paths) do
    local why = M.path_error(path)
    if why then
      return why
    end
    local key = path:gsub("/$", "")
    if seen[key] then
      return "paths names " .. key:sub(1, 60) .. " twice"
    end
    seen[key] = true
  end
  return nil
end

--- Check one entry of the file and bring it to the full form.
---@param id string
---@param value any  a reason text or the object form
---@return Rules.Waiver|nil entry
---@return string|nil why  without the file's name
local function entry_of(id, value)
  if type(value) == "string" then
    local why = M.reason_error(value)
    if why then
      return nil, ("reason for %s %s"):format(id, why)
    end
    return { reason = value }, nil
  end
  if type(value) ~= "table" or value == vim.NIL or (next(value) ~= nil and vim.islist(value)) then
    return nil, ("the waiver for %s must be a reason text or an object with reason, expires and paths"):format(id)
  end
  for key in pairs(value) do
    if not vim.tbl_contains(KEYS, key) then
      local shown = tostring(key):sub(1, 40)
      return nil, ("unknown key %q in the waiver for %s (keys: %s)"):format(shown, id, table.concat(KEYS, ", "))
    end
  end
  if value.reason == nil then
    return nil, ("the waiver for %s needs a reason"):format(id)
  end
  local why = M.reason_error(value.reason)
  if why then
    return nil, ("reason for %s %s"):format(id, why)
  end
  if vim.trim(value.reason) == "" then
    return nil, ("the waiver for %s needs a reason that says something"):format(id)
  end
  local entry = { reason = value.reason }
  if value.expires ~= nil then
    if not M.valid_date(value.expires) then
      return nil, ("expires for %s must be a calendar date in the form YYYY-MM-DD"):format(id)
    end
    entry.expires = value.expires
  end
  if value.paths ~= nil then
    local pwhy = M.paths_error(value.paths)
    if pwhy then
      return nil, ("paths for %s: %s"):format(id, pwhy)
    end
    entry.paths = vim.deepcopy(value.paths)
  end
  return entry, nil
end

--- Check the waiver of one id as the API takes it (the object form, fields already typed) and bring it to the full form.
---@param id string
---@param fields { reason?: any, expires?: any, paths?: any }
---@return Rules.Waiver|nil entry
---@return string|nil why
function M.entry(id, fields)
  return entry_of(id, { reason = fields.reason, expires = fields.expires, paths = fields.paths })
end

--- Why an id cannot be a key of the file, or nil.
---@param id any
---@return string|nil why
function M.id_error(id)
  if type(id) ~= "string" or id == "" then
    return "a rule id must be a non-empty text"
  end
  if chars(id) > M.MAX_ID_LEN or id:find("[%z\1-\31\127]") then
    return ("a rule id has at most %d characters and no control character"):format(M.MAX_ID_LEN)
  end
  return nil
end

--- Parse the text of a waivers file. Every field is re-validated; nothing is skipped.
---@param raw string
---@param label string  how an error names the file (the path for a user, `.rules-waivers.json` for a document)
---@return Rules.WaiverEntries|nil entries
---@return string|nil err
function M.parse(raw, label)
  -- a byte order mark (Notepad, Windows PowerShell 5.1 `Set-Content -Encoding UTF8`) is no part of the JSON: the loader
  -- (`readfile`) drops it, so the write door and the document must too, or one file would be two things
  raw = raw:gsub("^\239\187\191", "")
  local ok, decoded = safe_error.safe_call(vim.json.decode, raw)
  if not ok or type(decoded) ~= "table" then
    return nil, label .. ": could not parse as JSON"
  end

  -- `{}` decodes ambiguously (empty object or empty list) -- only reject a
  -- genuinely non-empty list, e.g. `["DEP-01", "DEP-02"]`, a natural mistake
  -- for "these are waived" that would otherwise silently waive nothing.
  if next(decoded) ~= nil and vim.islist(decoded) then
    return nil, label .. ': must be a JSON object of {"RULE-ID": "reason"}, not a list'
  end

  local entries, count = {}, 0
  for id, value in pairs(decoded) do
    local id_why = M.id_error(id)
    if id_why then
      return nil, ("%s: %s"):format(label, id_why)
    end
    local entry, why = entry_of(id, value)
    if not entry then
      return nil, ("%s: %s"):format(label, why)
    end
    entries[id] = entry
    count = count + 1
    if count > M.MAX_WAIVERS then
      return nil, ("%s: more than %d waiver entries"):format(label, M.MAX_WAIVERS)
    end
  end
  return entries, nil
end

-- ── the file ────────────────────────────────────────────────────────────────────

--- The path of the waivers file of a project.
---@param root string
---@return string
function M.path(root)
  return root .. "/" .. M.FILE
end

--- Load `<root>/.rules-waivers.json` in full. A missing file means no waivers and is not an error; one that exists
--- and cannot be used is.
---@param root string
---@return Rules.WaiverEntries entries  `{}` on an error
---@return string|nil error
function M.load_entries(root)
  local path = M.path(root)
  if vim.fn.filereadable(path) == 0 then
    -- a folder or a dangling link where the file belongs is a file that exists and cannot be used
    if vim.uv.fs_lstat(path) then
      return {}, path .. ": could not read (not a readable file)"
    end
    return {}, nil
  end

  -- ERR-01: `filereadable` above only checks openability at that instant --
  -- a TOCTOU window (removed/renamed/locked before this read) means
  -- `readfile` can still throw rather than return an error value.
  local read_ok, lines = safe_error.safe_call(vim.fn.readfile, path)
  if not read_ok then
    return {}, ("%s: could not read (%s)"):format(path, lines.message)
  end

  local entries, err = M.parse(table.concat(lines, "\n"), path)
  if not entries then
    return {}, err
  end
  return entries, nil
end

--- Load `<root>/.rules-waivers.json` as `{ [id] = reason }` -- the shape older callers read. A waiver in the object
--- form is its reason here; use `load_entries` for the expiry and the paths.
---@param root string
---@return Rules.Waivers waivers
---@return string|nil error
function M.load(root)
  local entries, err = M.load_entries(root)
  local out = {}
  for id, entry in pairs(entries) do
    out[id] = entry.reason
  end
  return out, err
end

--- The text of a waivers file for these entries: sorted keys, two spaces, LF and a final newline. A waiver with only a
--- reason is written in the short form (the old shape), any other as an object.
---@param entries Rules.WaiverEntries
---@return string
function M.encode(entries)
  local json = require("lib.nvim.json.canonical")
  local doc = {}
  for id, entry in pairs(entries) do
    if entry.expires == nil and entry.paths == nil then
      doc[id] = entry.reason
    else
      doc[id] = json.object({
        reason = entry.reason,
        expires = entry.expires,
        paths = entry.paths and json.array(vim.deepcopy(entry.paths)) or nil,
      })
    end
  end
  return json.encode(json.object(doc), { indent = 2 }) .. "\n"
end

--- The ids of the waivers that are expired on `today`, sorted.
---@param entries Rules.WaiverEntries
---@param today string
---@return string[] ids
function M.expired(entries, today)
  local out = {}
  for id, entry in pairs(entries) do
    if M.is_expired(entry, today) then
      out[#out + 1] = id
    end
  end
  table.sort(out)
  return out
end

--- Waiver ids that don't match any loaded rule -- a rule that was renamed,
--- retired, or simply mistyped in `.rules-waivers.json` leaves an entry that
--- silently protects nothing, forever, with no indication it stopped
--- mattering. Pure data; see `health.lua` for where this surfaces.
---@param waivers table<string, any>
---@param rules Rules.ParsedRule[]
---@return string[] orphaned  waiver ids with no matching rule, sorted
function M.orphaned(waivers, rules)
  local known = {}
  for _, r in ipairs(rules) do
    known[r.id] = true
  end
  local orphaned = {}
  for id in pairs(waivers) do
    if not known[id] then
      orphaned[#orphaned + 1] = id
    end
  end
  table.sort(orphaned)
  return orphaned
end

-- ── paths of a waiver against the files of a finding ────────────────────────────

--- A path with `/`, absolute, `.` and `..` resolved, nothing expanded: a folder called `$HOME` or `~x` is that folder
--- (`vim.fs.normalize` would read the variable).
---@param path string
---@return string
local function normalized(path)
  return (vim.fs.normalize(vim.fn.fnamemodify(path, ":p"), { expand_env = false }):gsub("/+$", ""))
end

--- A path with `/`, absolute, `.` and `..` resolved, the real path where the file system has one (links, 8.3 names).
--- A file that does not exist (yet) takes the real path of its nearest existing folder.
---@param path string
---@return string
local function real_of(path)
  local normal = normalized(path)
  local tail = {}
  local head = normal
  while head ~= "" do
    local real = vim.uv.fs_realpath(head)
    if real then
      local out = vim.fs.normalize(real, { expand_env = false }):gsub("/+$", "")
      for i = #tail, 1, -1 do
        out = out .. "/" .. tail[i]
      end
      return out
    end
    local parent, name = head:match("^(.*)/([^/]*)$")
    if not parent or parent == head then
      break
    end
    tail[#tail + 1] = name
    head = parent
  end
  return normal
end

--- A function that tells where a file is in the project: its path relative to `root` with `/`, or nil when it is not a
--- file inside it (the root itself included). Both sides are compared by real path, so a link, a short Windows name or
--- `/var` against `/private/var` does not matter.
---@param root string
---@return fun(file: string): string|nil
function M.relativizer(root)
  local base = real_of(root)
  local key = CASE_INSENSITIVE and base:lower() or base
  local folders = {}
  return function(file)
    local normal = normalized(file)
    local dir, name = normal:match("^(.*)/([^/]*)$")
    if not dir or name == "" then
      return nil
    end
    local real_dir = folders[dir]
    if not real_dir then
      real_dir = real_of(dir)
      folders[dir] = real_dir
    end
    local full = real_dir .. "/" .. name
    local compare = CASE_INSENSITIVE and full:lower() or full
    if compare:sub(1, #key + 1) ~= key .. "/" then
      return nil
    end
    local rel = full:sub(#key + 2)
    return rel ~= "" and rel or nil
  end
end

---@type table<string, any>
local glob_cache = {}

--- Whether `rel` (a path relative to the project root) is in one of `paths`: the same file, a file under a folder
--- with that name, or a match of a glob on the whole path or on a folder above it. Matched as written (case counts). An
--- entry with glob characters is tried as a name FIRST: `pages/[id].tsx` is the file of that name (a real Next.js route)
--- as well as the glob that matches `pages/i.tsx` and `pages/d.tsx`.
---@param paths string[]
---@param rel string
---@return boolean
function M.path_matches(paths, rel)
  for _, path in ipairs(paths) do
    local body = path:gsub("/$", "")
    if rel == body or rel:sub(1, #body + 1) == body .. "/" then
      -- the name as written, also when it has glob characters: `pages/[id].tsx` is that file
      return true
    end
    if has_glob(body) then
      local pattern = glob_cache[body]
      if pattern == nil then
        local ok, compiled = pcall(vim.glob.to_lpeg, body)
        pattern = ok and compiled or false
        glob_cache[body] = pattern
      end
      if pattern then
        -- the glob may name the file or a folder above it
        local from = 1
        while true do
          local slash = rel:find("/", from, true)
          local piece = slash and rel:sub(1, slash - 1) or rel
          if pattern:match(piece) then
            return true
          end
          if not slash then
            break
          end
          from = slash + 1
        end
      end
    end
  end
  return false
end

return M
