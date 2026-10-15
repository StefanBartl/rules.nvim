---@module 'rules.contract'
---@brief The documents of `rules-export/1`: what the engine tells a machine about a ruleset (read only).
---@description
--- Built on `lib.nvim.contract.doc` (head, seal, canonical bytes, 8 MiB limit, no path of this machine). What a
--- document CONTAINS is this module's: the families with their counters, the rules, the sources, the gates, the
--- next free id of a family.
---
--- Every rule carries the `etag` of the FILE it lives in (`sha256:` and 16 hex digits of its bytes), the version a
--- later write compares against. A rule that is the only rule of its file (the one-file-per-rule form) has
--- `etag_scope = "rule"`; a rule in a document with many rules has `etag_scope = "file"`: a change to any rule of
--- the document changes the etag of all of them.
---
--- A `check` that holds a Lua function (a `lua_predicate`) cannot be written as data: it is sent without the
--- function, with `editable = false`, and a client must not write it back.
---
--- The ids a "next free id" looks at are the LOADED rules (`basis = "loaded"`); the ids of retired rules join them
--- when `rules-ops/1` defines retiring (`engine-rules-ops`).
---
--- Not its job: parsing a request (`rules.api`), reading rule files (`rules.engine.loader`), writing (`rules-ops/1`).

local json = require("lib.nvim.json.canonical")
local etag = require("lib.nvim.fs.etag")
local errors = require("lib.nvim.contract.errors")
local expand_path = require("lib.nvim.cross.fs.expand_path")
local doc_mod = require("lib.nvim.contract.doc")

local loader = require("rules.engine.loader")
local parser = require("rules.engine.parser")

local M = {}

M.SCHEMA = 1
M.PLUGIN = "rules.nvim"
M.ENGINE_VERSION = "0.1.0"

---The most rules one `list` answers; a client pages for the rest.
M.MAX_LIST_ITEMS = 500
M.DEFAULT_LIST_ITEMS = 100

M.SEVERITIES = { "critical", "recommended", "nice-to-have" }

local plugin_root =
  vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")))))

local d = doc_mod.new({
  plugin = M.PLUGIN,
  schema = M.SCHEMA,
  scope_key = "source",
  engine_version = M.ENGINE_VERSION,
  plugin_root = plugin_root,
  too_large_hint = "ask for a page (limit, offset) or one family",
})

-- Seams for specs and golden files: read at call time, so a spec replaces them on this module.
local base_clock, base_engine_info = d.clock, d.engine_info
d.clock = function()
  return M.clock()
end
d.engine_info = function()
  return M.engine_info()
end

---@return string
function M.clock()
  return base_clock()
end

---@return { version: string, git: string, nvim: string }
function M.engine_info()
  return base_engine_info()
end

---The document builder (head, seal, encode, error_doc) of this contract.
M.doc = d

-- ── the source ───────────────────────────────────────────────────────────────────

---@class Rules.Contract.Opts
---@field rulesets? string[]            files or directories (`@vault/<name>`: one of the vault); default: `rules.settings`
---@field gates? table<string, string[]>  default: see `rules.settings`
---@field vault? string                 the rules-vault; default `setup({ vault })`, `$RULES_VAULT`, then the project file
---@field project? string               the root whose `.rules.json` is read; no project, no project file
---@field trust? string[]              folders whose rulesets are trusted (`setup({ trust })`, `--trust`): see `rules.settings`

---Paths that differ only in case are one folder on Windows and (by default) on macOS.
local CASE_INSENSITIVE = vim.fn.has("win32") == 1 or vim.fn.has("mac") == 1

---What the call asked for and `setup()`, the project file and the vault say, ranked (`rules.settings`). The warnings are
---shown once each.
---@param opts Rules.Contract.Opts|nil
---@return Rules.Settings
local function settings_of(opts)
  local settings = require("rules.settings")
  local res = settings.resolve({
    rulesets = opts and opts.rulesets,
    gates = opts and opts.gates,
    vault = opts and opts.vault,
    project = opts and opts.project,
    trust = opts and opts.trust,
  })
  settings.notify(res)
  return res
end

---The options a front end that works on the project in its working directory (the editor) hands to the contract.
---@param extra? Rules.Contract.Opts
---@return Rules.Contract.Opts
function M.editor_opts(extra)
  return vim.tbl_extend("force", { project = vim.fn.getcwd() }, extra or {})
end

---@param opts Rules.Contract.Opts|nil
---@return string[] paths  expanded, `/`-separated, absolute; a ruleset listed twice (or spelled another way) once
---@return string|nil err  a settings file that cannot be used, a vault that is no folder: no path of this machine in it
local function ruleset_paths(opts)
  local res = settings_of(opts)
  local given = res.rulesets
  local out, seen = {}, {}
  for _, path in ipairs(given) do
    local expanded = (vim.fs.normalize(vim.fn.fnamemodify(expand_path(path), ":p")):gsub("/+$", ""))
    -- the real path unifies spellings the string cannot (8.3 short names on Windows, links); a path that does not
    -- exist (yet) keeps its own spelling
    local real = vim.uv.fs_realpath(expanded)
    local key = real and vim.fs.normalize(real):gsub("/+$", "") or expanded
    if CASE_INSENSITIVE then
      key = vim.fn.tolower(key)
    end
    if not seen[key] then
      seen[key] = true
      out[#out + 1] = expanded
    end
  end
  return out, require("rules.settings").error_text(res, true)
end

---@param opts Rules.Contract.Opts|nil
---@return table<string, string[]>
local function gates_of(opts)
  return settings_of(opts).gates
end

---The root a document is scoped to (`source.id` is its last part); `nil` when no ruleset is configured.
---@param opts Rules.Contract.Opts|nil
---@return string|nil
function M.root_of(opts)
  return (ruleset_paths(opts))[1]
end

---The name each ruleset goes by in a document: the last part of its path. Only where two rulesets would get the
---same name (both are called `Checklists`) the folder above is added (`wkdbook-Lua/Checklists`): a name that is
---always taken from higher up would put a folder of this machine (a user name) into every document.
---Two rulesets that still share a name after that (two checkouts of one project, same folder names) are told apart
---by a number: the first in the order of the configuration keeps the name, the next ones are `<name>#2`, `<name>#3`.
---@param paths string[]  without duplicates (`ruleset_paths`)
---@return table<string, string> names  root -> name
local function root_names(paths)
  local taken = {}
  for _, root in ipairs(paths) do
    local key = vim.fs.basename(root):lower()
    taken[key] = (taken[key] or 0) + 1
  end
  local names, used = {}, {}
  for _, root in ipairs(paths) do
    local name = vim.fs.basename(root)
    local parent = vim.fs.basename(vim.fs.dirname(root))
    if taken[name:lower()] > 1 and parent ~= "" and parent ~= "." then
      name = parent .. "/" .. name
    end
    local unique, n = name, 1
    while used[unique:lower()] do
      n = n + 1
      unique = name .. "#" .. n
    end
    used[unique:lower()] = true
    names[root] = unique
  end
  return names
end

---The source-relative name of a file: `<ruleset name>/<path inside it>`; for a ruleset that is a file, its name.
---@param paths string[]
---@param names table<string, string>
---@param file string
---@return string
local function display_path(paths, names, file)
  local normal = vim.fs.normalize(vim.fn.fnamemodify(file, ":p"))
  local best, best_len = nil, -1
  for _, root in ipairs(paths) do
    local rel = d.relative(root, normal)
    if rel and #root > best_len then
      best, best_len = (names[root] .. "/" .. rel), #root
    elseif normal:lower() == root:lower() and #root > best_len then
      best, best_len = names[root], #root
    end
  end
  return best or ("<external>/" .. vim.fs.basename(normal))
end

---The name each ruleset goes by in a document (exported for the writer, which names a ruleset the same way).
---@param opts Rules.Contract.Opts|nil
---@return string[] paths
---@return table<string, string> names
---@return string|nil err  the settings cannot be used (`invalid_argument` as a document)
function M.rulesets(opts)
  local paths, err = ruleset_paths(opts)
  return paths, root_names(paths), err
end

---What the scan of these rulesets would read, as one text: every `.md` file with its size and modification time.
---`nil` when a file changed so recently that a second change in the same clock tick could go unseen (a stale
---answer must never be kept: the one place that writes the files, `rules-ops/1`, drops the cache itself).
---@param paths string[]
---@return string|nil
local function signature(paths)
  local fswalk = require("rules.engine.fswalk")
  local uv = vim.uv or vim.loop
  local parts = {}
  local now = os.time()
  for _, root in ipairs(paths) do
    local files = { root }
    if vim.fn.isdirectory(root) == 1 then
      files = {}
      for _, file in ipairs(fswalk.files(root)) do
        if file:match("%.md$") then
          files[#files + 1] = file
        end
      end
    end
    for _, file in ipairs(files) do
      local stat = uv.fs_stat(file)
      if not stat then
        return nil
      end
      if stat.mtime.sec >= now - 2 then
        return nil
      end
      parts[#parts + 1] = ("%s\t%d\t%d.%d"):format(file, stat.size, stat.mtime.sec, stat.mtime.nsec)
    end
  end
  table.sort(parts)
  return table.concat(paths, "\n") .. "\0" .. table.concat(parts, "\n")
end

---@type { key: string, view: Rules.Contract.View }|nil
local cache

---@param file string
---@return string|nil bytes
local function read_bytes(file)
  local fh = io.open(file, "rb")
  if not fh then
    return nil
  end
  local text = fh:read("*a")
  fh:close()
  return text
end

---A copy of a value without functions, and whether it had any.
---@param value any
---@return any copy
---@return boolean had_function
local function plain(value)
  local kind = type(value)
  if kind == "function" then
    return nil, true
  elseif kind ~= "table" then
    return value, false
  end
  local had = false
  if vim.islist(value) then
    local out = {}
    for _, item in ipairs(value) do
      local copy, fn = plain(item)
      had = had or fn
      out[#out + 1] = copy
    end
    return json.array(out), had
  end
  local out = {}
  for key, item in pairs(value) do
    if type(key) == "string" then
      local copy, fn = plain(item)
      had = had or fn
      if copy ~= nil then
        out[key] = copy
      end
    end
  end
  return json.object(out), had
end

---@class Rules.Contract.View
---@field paths string[]
---@field rules table[]              summaries, sorted by id
---@field full table<string, table>  id -> full entry
---@field abs table<string, string>   id -> absolute path of its file (never in a document)
---@field names table<string, string>  ruleset path -> the name it goes by in a document
---@field retired table[]              { id, family, source, replaced_by?, retired?, reason? }
---@field files table[]              { path, rules, etag }
---@field load_errors string[]
---@field rev string

---The rules that were retired: `<ruleset>/_retired/<FAMILY>/<ID>.md` (`rules-ops/1` `retire`). The loader does not
---read that folder, so a retired rule is never run; its id stays taken.
---@param paths string[]
---@param names table<string, string>
---@return table[]
local function retired_of(paths, names)
  local fswalk = require("rules.engine.fswalk")
  local out = {}
  for _, root in ipairs(paths) do
    local folder = root .. "/_retired"
    if vim.fn.isdirectory(folder) == 1 then
      for _, file in ipairs(fswalk.files(folder)) do
        local id = file:match("([^/]+)%.md$")
        if id then
          local entry = { id = id, family = parser.family_of(id), source = display_path({ root }, names, file) }
          local bytes = read_bytes(file) or ""
          local head = bytes:match("^%-%-%-\r?\n(.-)\r?\n%-%-%-")
          for key, value in (head or ""):gmatch("([%w_]+):%s*([^\r\n]*)") do
            if key == "replaced_by" or key == "retired" or key == "reason" then
              entry[key] = value
            end
          end
          out[#out + 1] = entry
        end
      end
    end
  end
  table.sort(out, function(a, b)
    return json.bytes_less(a.id, b.id)
  end)
  return out
end

---@param paths string[]
---@return Rules.Contract.View
local function build_view(paths)
  local names = root_names(paths)
  local parsed, load_errors = loader.load(paths)

  ---@type table<string, { etag: string, count: integer, one_file: boolean }>
  local by_file = {}
  for _, rule in ipairs(parsed) do
    local entry = by_file[rule.source_file]
    if not entry then
      local bytes = read_bytes(rule.source_file) or ""
      local lines = vim.split((bytes:gsub("\r\n", "\n")), "\n", { plain = true })
      entry = { etag = etag.of(bytes), count = 0, one_file = parser.classify(lines) == "rule" }
      by_file[rule.source_file] = entry
    end
    entry.count = entry.count + 1
  end

  local rules, full, abs = {}, {}, {}
  for _, rule in ipairs(parsed) do
    local file = by_file[rule.source_file]
    local check, had_function
    if rule.check ~= nil then
      check, had_function = plain(rule.check)
    end
    local summary = {
      id = rule.id,
      family = parser.family_of(rule.id),
      severity = rule.severity,
      title = rule.title or "",
      section = rule.section or "",
      source = display_path(paths, names, rule.source_file),
      line = rule.source_line,
      has_check = rule.check ~= nil,
      check_type = type(rule.check) == "table" and type(rule.check.type) == "string" and rule.check.type or nil,
      has_agent = rule.agent ~= nil,
      editable = not had_function,
      etag = file.etag,
      etag_scope = file.one_file and "rule" or "file",
    }
    rules[#rules + 1] = summary
    local entry = vim.deepcopy(summary)
    entry.text = rule.text or ""
    entry.check = check
    if rule.agent ~= nil then
      entry.agent = (plain(rule.agent))
    end
    full[rule.id] = entry
    abs[rule.id] = rule.source_file
  end
  table.sort(rules, function(a, b)
    return json.bytes_less(a.id, b.id)
  end)

  local files, lines = {}, {}
  for file, info in pairs(by_file) do
    files[#files + 1] = { path = display_path(paths, names, file), rules = info.count, etag = info.etag }
  end
  table.sort(files, function(a, b)
    return json.bytes_less(a.path, b.path)
  end)
  for _, f in ipairs(files) do
    lines[#lines + 1] = f.path .. "\t" .. f.etag
  end

  -- a message names files by their absolute path: the root becomes the name the ruleset goes by in a document
  local by_length = vim.deepcopy(paths)
  table.sort(by_length, function(a, b)
    return #a > #b
  end)
  local scrubbed = {}
  for _, message in ipairs(load_errors) do
    local text = (message:gsub("\\", "/"))
    for _, root in ipairs(by_length) do
      text = text:gsub(vim.pesc(root), (names[root]:gsub("%%", "%%%%")))
    end
    for _, root in ipairs(by_length) do
      text = d.redact(root, text)
    end
    scrubbed[#scrubbed + 1] = text
  end
  table.sort(scrubbed, json.bytes_less)

  return {
    paths = paths,
    names = names,
    abs = abs,
    retired = retired_of(paths, names),
    rules = rules,
    full = full,
    files = files,
    load_errors = scrubbed,
    rev = d.rev_of(lines),
  }
end

---Scan the configured rulesets into the shapes the documents use. The answer is kept while no `.md` file of the
---rulesets changed (size and modification time), so a persistent host does not parse the ruleset for every
---question; the table is shared, a caller must not change it.
---@param opts Rules.Contract.Opts|nil
---@return Rules.Contract.View|nil view
---@return Lib.Contract.Error|nil err
function M.view(opts)
  local paths, settings_err = ruleset_paths(opts)
  if settings_err then
    return nil, errors.fail("invalid_argument", settings_err)
  end
  if #paths == 0 then
    return nil, errors.fail("not_found", "no ruleset is configured (rulesets is empty)")
  end
  local key = signature(paths)
  if key and cache and cache.key == key then
    return cache.view, nil
  end
  local view = build_view(paths)
  cache = key and { key = key, view = view } or nil
  return view, nil
end

---Forget the kept scan (the writer of the rule files calls this after a write).
function M.clear_cache()
  cache = nil
end

---@param view Rules.Contract.View
---@return table[]
local function families_of(view)
  local order, by_family = {}, {}
  for _, rule in ipairs(view.rules) do
    local fam = by_family[rule.family]
    if not fam then
      fam = { family = rule.family, count = 0, critical = 0, recommended = 0, nice_to_have = 0, with_check = 0 }
      by_family[rule.family] = fam
      order[#order + 1] = fam
    end
    fam.count = fam.count + 1
    local key = rule.severity == "nice-to-have" and "nice_to_have" or rule.severity
    fam[key] = fam[key] + 1
    if rule.has_check then
      fam.with_check = fam.with_check + 1
    end
  end
  table.sort(order, function(a, b)
    return json.bytes_less(a.family, b.family)
  end)
  return order
end

---@param view Rules.Contract.View
---@param opts Rules.Contract.Opts|nil
---@return table[]
local function gates_doc(view, opts)
  local present = {}
  for _, rule in ipairs(view.rules) do
    present[rule.family] = (present[rule.family] or 0) + 1
  end
  local out = {}
  for name, families in pairs(gates_of(opts)) do
    local entry = { name = name, families = json.array(vim.deepcopy(families)), rules = 0, unknown = {} }
    for _, fam in ipairs(families) do
      if present[fam] then
        entry.rules = entry.rules + present[fam]
      else
        entry.unknown[#entry.unknown + 1] = fam
      end
    end
    entry.unknown = json.array(entry.unknown)
    out[#out + 1] = entry
  end
  table.sort(out, function(a, b)
    return json.bytes_less(a.name, b.name)
  end)
  return out
end

---@param view Rules.Contract.View
---@param kind string
---@return table
local function new_doc(view, kind)
  return d.head(d.kind(kind), view.paths[1])
end

-- ── the documents ────────────────────────────────────────────────────────────────

---`rules.hello`: what this engine is and can do. Reads no rule.
---@param opts Rules.Contract.Opts|nil
---@return table
function M.hello(opts)
  local doc = d.head(d.kind("hello"), M.root_of(opts))
  doc.schemas = json.array({ M.SCHEMA })
  doc.capabilities = json.array({ "hello", "snapshot", "list", "rule", "next_id", "sources", "ops" })
  doc.limits = json.object({
    list_items = M.MAX_LIST_ITEMS,
    request_bytes = 256 * 1024,
    doc_bytes = d.MAX_DOC_BYTES,
  })
  doc.enums = json.object({ severity = json.array(vim.deepcopy(M.SEVERITIES)) })
  doc.read_only = false
  doc.ops = json.array({ "new", "set", "retire", "reinstate", "move" })
  return doc
end

---`rules.snapshot`: families with their counters, every rule, the sources and the gates.
---@param opts Rules.Contract.Opts|nil
---@return table|nil doc
---@return Lib.Contract.Error|nil err
function M.snapshot(opts)
  local view, err = M.view(opts)
  if not view then
    return nil, err
  end
  local families = families_of(view)
  local doc = new_doc(view, "snapshot")
  doc.counts = json.object({ rules = #view.rules, families = #families, files = #view.files })
  doc.families = json.array(families)
  doc.rules = json.array(view.rules)
  doc.sources = json.array(view.files)
  doc.gates = json.array(gates_doc(view, opts))
  doc.retired = json.array(view.retired)
  doc.load_errors = json.array(view.load_errors)
  return d.seal(doc, view.rev), nil
end

---`rules.list`: a page of rules, optionally of one family or severity.
---@param params { family?: string, severity?: string, limit?: integer, offset?: integer }
---@param opts Rules.Contract.Opts|nil
---@return table|nil doc
---@return Lib.Contract.Error|nil err
function M.list(params, opts)
  params = params or {}
  if params.severity ~= nil and not vim.tbl_contains(M.SEVERITIES, params.severity) then
    return nil, errors.fail("invalid_argument", ("severity must be one of %s"):format(table.concat(M.SEVERITIES, ", ")))
  end
  local limit = params.limit or M.DEFAULT_LIST_ITEMS
  local offset = params.offset or 0
  if limit < 1 or limit > M.MAX_LIST_ITEMS then
    return nil, errors.fail("invalid_argument", ("limit must be from 1 to %d"):format(M.MAX_LIST_ITEMS))
  end
  if offset < 0 then
    return nil, errors.fail("invalid_argument", "offset must be 0 or more")
  end
  local view, err = M.view(opts)
  if not view then
    return nil, err
  end
  local picked = {}
  for _, rule in ipairs(view.rules) do
    if
      (params.family == nil or rule.family == params.family)
      and (params.severity == nil or rule.severity == params.severity)
    then
      picked[#picked + 1] = rule
    end
  end
  local items = {}
  for i = offset + 1, math.min(#picked, offset + limit) do
    items[#items + 1] = picked[i]
  end
  local doc = new_doc(view, "list")
  doc.total = #picked
  doc.offset = offset
  doc.limit = limit
  doc.items = json.array(items)
  return d.seal(doc, view.rev), nil
end

---`rules.rule`: one rule with its text, its check and the etag of its file.
---@param id string
---@param opts Rules.Contract.Opts|nil
---@return table|nil doc
---@return Lib.Contract.Error|nil err
function M.rule(id, opts)
  local view, err = M.view(opts)
  if not view then
    return nil, err
  end
  local entry = view.full[id]
  if not entry then
    return nil, errors.fail("not_found", ("no rule with the id %s"):format(id))
  end
  local doc = new_doc(view, "rule")
  doc.rule = json.object(entry)
  return d.seal(doc, view.rev), nil
end

---The largest whole number a JSON number carries exactly (2^53 - 1).
local MAX_SAFE = 9007199254740991

---How far every family is numbered: the highest number taken (a loaded rule or a retired one), the width of the
---number and how many ids that are. The digits are compared as text (`top`, no leading zeros), so an id of any
---length counts; `highest` is that number, held at 2^53 - 1 where it would be larger (a JSON number is exact up to
---there) -- `next` is built from `top` and stays exact.
---@param view Rules.Contract.View
---@return table<string, { highest: integer, top: string, width: integer, count: integer }>
local function numbering(view)
  local seen = {}
  for _, list in ipairs({ view.rules, view.retired }) do
    for _, rule in ipairs(list) do
      local fam, num = rule.id:match("^(%a+)%-(%d+)$")
      if fam then
        local s = seen[fam] or { highest = 0, top = "", width = 2, count = 0 }
        local digits = num:gsub("^0+", "")
        if #digits > #s.top or (#digits == #s.top and digits > s.top) then
          s.top = digits
          s.highest = #digits > 15 and math.min(tonumber(digits) or MAX_SAFE, MAX_SAFE) or tonumber(digits) or 0
        end
        s.width = math.max(s.width, #num)
        s.count = s.count + 1
        seen[fam] = s
      end
    end
  end
  return seen
end

---The longest id a rule may have (`docs/RULESET-FORMAT.md`): a longer one would not read back.
local MAX_ID_BYTES = 100

---The id one past the highest number of a family, in the width the family uses (at least two digits). `nil` when
---that id would be longer than an id may be: there is no id left in the family.
---@param family string
---@param s { top: string, width: integer }|nil  nil: nothing is numbered in this family yet
---@return string|nil
local function successor(family, s)
  local top, width = s and s.top or "", s and s.width or 2
  local out, carry = {}, 1
  for i = #top, 1, -1 do
    local v = top:byte(i) - 48 + carry
    carry = v >= 10 and 1 or 0
    out[#out + 1] = string.char(48 + v % 10)
  end
  if carry == 1 then
    out[#out + 1] = "1"
  end
  local digits = table.concat(out):reverse()
  local id = family .. "-" .. ("0"):rep(width - #digits) .. digits
  if #id > MAX_ID_BYTES then
    return nil
  end
  return id
end

---The next free id of a family in a scan: one past the highest id taken, loaded or retired, with the width the
---family uses (at least two digits). An id is never given twice. `nil` when the id would be longer than an id may be.
---@param view Rules.Contract.View
---@param family string
---@return string|nil id
function M.next_free(view, family)
  return successor(family, numbering(view)[family])
end

---`rules.next_id`: the next free id of a family (or of every family).
---@param params { family?: string }
---@param opts Rules.Contract.Opts|nil
---@return table|nil doc
---@return Lib.Contract.Error|nil err
function M.next_id(params, opts)
  params = params or {}
  if params.family ~= nil and not params.family:match("^%a+$") then
    return nil, errors.fail("invalid_argument", "family must be letters only (the part of an id before the first '-')")
  end
  local view, err = M.view(opts)
  if not view then
    return nil, err
  end
  local seen = numbering(view)
  local function entry(fam)
    local s = seen[fam] or { highest = 0, count = 0 }
    return { family = fam, highest = s.highest, count = s.count, next = successor(fam, seen[fam]) }
  end
  local out = {}
  if params.family then
    out[1] = entry(params.family)
  else
    for fam in pairs(seen) do
      out[#out + 1] = entry(fam)
    end
    table.sort(out, function(a, b)
      return json.bytes_less(a.family, b.family)
    end)
  end
  local doc = new_doc(view, "next_id")
  doc.basis = json.array({ "loaded", "retired" })
  doc.items = json.array(out)
  return d.seal(doc, view.rev), nil
end

---`rules.sources`: the files the rules come from, with the etag of each.
---@param opts Rules.Contract.Opts|nil
---@return table|nil doc
---@return Lib.Contract.Error|nil err
function M.sources(opts)
  local view, err = M.view(opts)
  if not view then
    return nil, err
  end
  local doc = new_doc(view, "sources")
  doc.items = json.array(view.files)
  doc.load_errors = json.array(view.load_errors)
  return d.seal(doc, view.rev), nil
end

---The error document of a failure (the root is hidden in the message).
---@param err Lib.Contract.Error
---@param opts Rules.Contract.Opts|nil
---@return table
function M.error_doc(err, opts)
  return d.error_doc(err, M.root_of(opts))
end

return M
