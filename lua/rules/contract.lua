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
---@field rulesets? string[]            files or directories; default `setup({ rulesets })`
---@field gates? table<string, string[]>  default `setup({ gates })`

---@param opts Rules.Contract.Opts|nil
---@return string[] paths  expanded, `/`-separated, absolute
local function ruleset_paths(opts)
  local given = opts and opts.rulesets
  if given == nil then
    given = require("rules.config").get().rulesets
  end
  local out = {}
  for _, path in ipairs(given or {}) do
    local expanded = vim.fs.normalize(vim.fn.fnamemodify(expand_path(path), ":p"))
    out[#out + 1] = (expanded:gsub("/+$", ""))
  end
  return out
end

---@param opts Rules.Contract.Opts|nil
---@return table<string, string[]>
local function gates_of(opts)
  local gates = opts and opts.gates
  if gates == nil then
    gates = require("rules.config").get().gates
  end
  return gates or {}
end

---The root a document is scoped to (`source.id` is its last part); `nil` when no ruleset is configured.
---@param opts Rules.Contract.Opts|nil
---@return string|nil
function M.root_of(opts)
  return ruleset_paths(opts)[1]
end

---The name a ruleset goes by in a document: its folder and the folder above (`wkdbook-Lua/Checklists`), so two
---rulesets that are both called `Checklists` stay apart.
---@param root string
---@return string
local function root_name(root)
  local parent = vim.fs.basename(vim.fs.dirname(root))
  local name = vim.fs.basename(root)
  if parent == "" or parent == "." then
    return name
  end
  return parent .. "/" .. name
end

---The source-relative name of a file: `<ruleset name>/<path inside it>`; for a ruleset that is a file, its name.
---@param paths string[]
---@param file string
---@return string
local function display_path(paths, file)
  local normal = vim.fs.normalize(vim.fn.fnamemodify(file, ":p"))
  local best, best_len = nil, -1
  for _, root in ipairs(paths) do
    local rel = d.relative(root, normal)
    if rel and #root > best_len then
      best, best_len = (root_name(root) .. "/" .. rel), #root
    elseif normal:lower() == root:lower() and #root > best_len then
      best, best_len = root_name(root), #root
    end
  end
  return best or ("<external>/" .. vim.fs.basename(normal))
end

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
---@field files table[]              { path, rules, etag }
---@field load_errors string[]
---@field rev string

---Scan the configured rulesets once into the shapes the documents use.
---@param opts Rules.Contract.Opts|nil
---@return Rules.Contract.View|nil view
---@return Lib.Contract.Error|nil err
function M.view(opts)
  local paths = ruleset_paths(opts)
  if #paths == 0 then
    return nil, errors.fail("not_found", "no ruleset is configured (rulesets is empty)")
  end

  local parsed, load_errors = loader.load(paths)

  ---@type table<string, { etag: string, count: integer }>
  local by_file = {}
  for _, rule in ipairs(parsed) do
    local entry = by_file[rule.source_file]
    if not entry then
      entry = { etag = etag.of(read_bytes(rule.source_file) or ""), count = 0 }
      by_file[rule.source_file] = entry
    end
    entry.count = entry.count + 1
  end

  local rules, full = {}, {}
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
      source = display_path(paths, rule.source_file),
      line = rule.source_line,
      has_check = rule.check ~= nil,
      check_type = type(rule.check) == "table" and type(rule.check.type) == "string" and rule.check.type or nil,
      has_agent = rule.agent ~= nil,
      editable = not had_function,
      etag = file.etag,
      etag_scope = file.count == 1 and "rule" or "file",
    }
    rules[#rules + 1] = summary
    local entry = vim.deepcopy(summary)
    entry.text = rule.text or ""
    entry.check = check
    if rule.agent ~= nil then
      entry.agent = (plain(rule.agent))
    end
    full[rule.id] = entry
  end
  table.sort(rules, function(a, b)
    return json.bytes_less(a.id, b.id)
  end)

  local files, lines = {}, {}
  for file, info in pairs(by_file) do
    files[#files + 1] = { path = display_path(paths, file), rules = info.count, etag = info.etag }
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
      text = text:gsub(vim.pesc(root), (root_name(root):gsub("%%", "%%%%")))
    end
    for _, root in ipairs(by_length) do
      text = d.redact(root, text)
    end
    scrubbed[#scrubbed + 1] = text
  end
  table.sort(scrubbed, json.bytes_less)

  return {
    paths = paths,
    rules = rules,
    full = full,
    files = files,
    load_errors = scrubbed,
    rev = d.rev_of(lines),
  },
    nil
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
  doc.capabilities = json.array({ "hello", "snapshot", "list", "rule", "next_id", "sources" })
  doc.limits = json.object({
    list_items = M.MAX_LIST_ITEMS,
    request_bytes = 256 * 1024,
    doc_bytes = d.MAX_DOC_BYTES,
  })
  doc.enums = json.object({ severity = json.array(vim.deepcopy(M.SEVERITIES)) })
  doc.read_only = true
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
  ---@type table<string, { highest: integer, width: integer, count: integer }>
  local seen = {}
  for _, rule in ipairs(view.rules) do
    local fam, num = rule.id:match("^(%a+)%-(%d+)$")
    if fam then
      local s = seen[fam] or { highest = 0, width = 2, count = 0 }
      s.highest = math.max(s.highest, tonumber(num) or 0)
      s.width = math.max(s.width, #num)
      s.count = s.count + 1
      seen[fam] = s
    end
  end
  local function entry(fam)
    local s = seen[fam] or { highest = 0, width = 2, count = 0 }
    return {
      family = fam,
      highest = s.highest,
      count = s.count,
      next = ("%s-%0" .. s.width .. "d"):format(fam, s.highest + 1),
    }
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
  doc.basis = json.array({ "loaded" })
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
