---@module 'rules.ops'
---@brief The write door of `rules-ops/1`: new, set, retire, reinstate, move.
---@description
--- Built on `lib.nvim.contract.ops` (the shape check of the whole request first, one entry per operation, `dry_run`,
--- `client_op_id`, no path of this machine in an entry). What an operation DOES is here.
---
--- One rule is one file (`<ruleset>/_rules/<FAMILY>/<ID>.md`), so a rule is changed, created or retired without
--- touching another rule's text; where it stands in a generated document is the layout's business (`{{rule ID}}`).
---
---  - `new` { family, title, severity, text?, check?, agent?, after? | before? | (layout, section, first?, nth?), ruleset? }
---    creates the file with the next free id (loaded and retired ids count: an id is never given twice) under the
---    ruleset's lock, and puts the rule in a layout when a place is given. `inverse`: `retire`. The entry may carry
---    `warnings` (a list of texts): the vault is behind its upstream, so another machine may make the same id.
---    A warning, not a refusal; the engine never pulls, commits or pushes.
---  - `set` { id, patch = { severity?, title?, text?, check?, agent? }, if_match? } changes parts of the rule's file by
---    editing lines (`rules.engine.rule_edit`); `if_match` is the etag the client saw, a changed file is a
---    `conflict` with `expected` and `actual`. `null` in `check`/`agent` removes it. `inverse`: `set` back.
---  - `retire` { id, replaced_by?, reason?, if_match? } moves the file to `<ruleset>/_retired/<FAMILY>/<ID>.md`
---    (the loader does not read that folder, the id stays taken) and takes its place in the layouts out.
---    `inverse`: `reinstate` with `places` (every layout that held the rule).
---  - `reinstate` { id, place? | places? } brings a retired rule back, to where it came from. `places` is
---    `{ [layout output] = place }`. `inverse`: `retire`.
---  - `move` { id, after? | before? | (layout, section, first?, nth?) } moves the `{{rule ID}}` line of a rule, within a
---    layout or to another one; the rule's file is not touched. `inverse`: `move` back.
---
--- A rule that lives in a document with many rules (`etag_scope = "file"`) is not written: migrate it first
--- (`scripts/ruleset.lua migrate`). A rule whose check holds a Lua function is not patched in `check` or `agent`.
---
--- Every operation that touches more than one file takes a step back when a later step fails (the files it wrote
--- return to their bytes, a file it created is removed); what could not be taken back is named
--- (`rollback_incomplete`). The documents are made again once, at the end (`catalog`), also after a partial failure.
---
--- Not its job: reading (`rules.contract`), the text of a rule file (`rules.engine.rule_edit`), a layout
--- (`rules.engine.layout_edit`).

local json = require("lib.nvim.json.canonical")
local etag = require("lib.nvim.fs.etag")
local ops_lib = require("lib.nvim.contract.ops")
local errors = require("lib.nvim.contract.errors")
local with_lock = require("lib.nvim.fs.with_lock")
local create_exclusive = require("lib.nvim.fs.create_exclusive")
local write_atomic = require("lib.nvim.fs.write.atomic")

local contract = require("rules.contract")
local parser = require("rules.engine.parser")
local rule_edit = require("rules.engine.rule_edit")
local layout_edit = require("rules.engine.layout_edit")
local catalog = require("rules.engine.catalog")
local fswalk = require("rules.engine.fswalk")

local M = {}

M.MAX_TITLE = 200
M.MAX_TEXT = 20000
M.MAX_REASON = 300
M.FAMILY_MAX = 12

---Why a family cannot be given to `new`, or `nil` when it can: uppercase letters `A-Z` only (the form of every family of
---a ruleset: `DEP`, `LUA`), 1 to `FAMILY_MAX`. Lower or mixed case is refused, not changed: a mistyped word of a title
---(`Fix`) must not become a family, and `dep` would be another family than `DEP` where the file system tells the
---folders apart and the same folder where it does not. The text goes after the word "family" (the form says "Family").
---@param family any
---@return string|nil why
function M.family_error(family)
  if type(family) ~= "string" or not family:match("^[A-Z]+$") or #family > M.FAMILY_MAX then
    return ("must be 1 to %d uppercase letters A-Z (e.g. DEP)"):format(M.FAMILY_MAX)
  end
  return nil
end

---@class Rules.OpsCtx
---@field root string               the first ruleset (what an error hides)
---@field paths string[]
---@field names table<string, string>
---@field opts Rules.Contract.Opts
---@field dry boolean
---@field touched table<string, true>   rulesets whose documents have to be made again (marked before a write starts)
---@field owner table<table, string>     result entry -> the ruleset it changed

local door

-- ── small helpers ───────────────────────────────────────────────────────────────

---@param path string
---@return string|nil
local function read_bytes(path)
  local fh = io.open(path, "rb")
  if not fh then
    return nil
  end
  local text = fh:read("*a")
  fh:close()
  return text
end

---@param ctx Rules.OpsCtx
---@param err any
---@param info? table
---@return table
local function fail(ctx, err, info)
  return door.failure(ctx.root, err, info)
end

---@param code string
---@param message string
---@param details? table
---@return table
local function refuse(code, message, details)
  return door.refuse(code, message, details)
end

---The ruleset (its path) a name or the first one stands for.
---@param ctx Rules.OpsCtx
---@param name string|nil
---@return string|nil root
---@return string|nil why
local function ruleset(ctx, name)
  if name == nil then
    return ctx.paths[1], nil
  end
  for _, path in ipairs(ctx.paths) do
    if ctx.names[path] == name or vim.fs.basename(path) == name then
      return path, nil
    end
  end
  return nil, ("no ruleset is called %q"):format(name)
end

---The ruleset a file belongs to.
---@param ctx Rules.OpsCtx
---@param file string
---@return string|nil
local function ruleset_of(ctx, file)
  local normal = vim.fs.normalize(file)
  local best
  for _, path in ipairs(ctx.paths) do
    if contract.doc.relative(path, normal) and (not best or #path > #best) then
      best = path
    end
  end
  return best
end

---A folder with a name made by the writer: letters, digits, `-`, `_` and `.` (what an id may be).
---@param path string
---@return boolean
local function is_folder(path)
  return vim.fn.isdirectory(path) == 1
end

---@class Rules.Layout
---@field path string
---@field text string
---@field output string

---Every layout of a ruleset with its text.
---@param root string
---@return Rules.Layout[]
local function layouts_of(root)
  local out = {}
  if not is_folder(root) then
    return out
  end
  for _, file in ipairs(fswalk.files(root)) do
    if file:match("%.md$") and not file:find("/_retired/", 1, true) then
      local text = read_bytes(file)
      if text and text:find("kind:%s*layout") then
        local lines = vim.split((text:gsub("\r\n", "\n")), "\n", { plain = true })
        if parser.classify(lines) == "layout" then
          local layout = catalog.parse_layout(text)
          if layout then
            out[#out + 1] = { path = file, text = text, output = layout.output }
          end
        end
      end
    end
  end
  table.sort(out, function(a, b)
    return a.path < b.path
  end)
  return out
end

---@class Rules.Tx
---@field written table<string, string>   path -> its bytes before (a file that was changed)
---@field created string[]                files this operation made
---@field deleted table<string, string>   path -> its bytes before (a file that was removed)

---@return Rules.Tx
local function new_tx()
  return { written = {}, created = {}, deleted = {} }
end

---Put every file back as it was. Returns what could not be put back.
---@param tx Rules.Tx
---@return string[] not_restored
local function rollback(tx)
  local bad = {}
  for path, bytes in pairs(tx.deleted) do
    local ok = write_atomic(path, bytes, { mkdirp = true })
    if not ok then
      bad[#bad + 1] = path
    end
  end
  for path, bytes in pairs(tx.written) do
    local ok = write_atomic(path, bytes)
    if not ok then
      bad[#bad + 1] = path
    end
  end
  for _, path in ipairs(tx.created) do
    local removed = os.remove(path)
    if not removed and vim.uv.fs_stat(path) then
      bad[#bad + 1] = path
    end
  end
  table.sort(bad)
  return bad
end

---The refusal of an operation that stopped half way, after the step back.
---@param ctx Rules.OpsCtx
---@param tx Rules.Tx
---@param message string
---@return table entry
local function stopped(ctx, tx, message)
  local bad = rollback(tx)
  contract.clear_cache()
  if #bad > 0 then
    local shown = {}
    for _, path in ipairs(bad) do
      shown[#shown + 1] = contract.doc.safe_path(ctx.root, path)
    end
    return refuse(
      "rollback_incomplete",
      message .. "; these files could not be put back: " .. table.concat(shown, ", "),
      { not_restored = json.array(shown) }
    )
  end
  return refuse("io", message)
end

---Write a file of the transaction: keep its old bytes first.
---@param tx Rules.Tx
---@param path string
---@param text string
---@return boolean ok
---@return string|nil err
local function write_in(tx, path, text)
  local kept = false
  if tx.written[path] == nil and not vim.tbl_contains(tx.created, path) then
    tx.written[path] = read_bytes(path) or ""
    kept = true
  end
  local ok, err = write_atomic(path, text)
  if not ok and kept then
    -- an atomic write that failed changed nothing: there is nothing to put back for this file
    tx.written[path] = nil
  end
  return ok, err
end

---Run `fn` under the lock of a ruleset: one writer at a time over all of its files.
---@param ctx Rules.OpsCtx
---@param root string
---@param fn fun(): table
---@return table entry
local function locked(ctx, root, fn)
  local entry, err, info = with_lock(root .. "/.rules-ops", fn, { wait_ms = 2000 })
  if entry == nil then
    return fail(ctx, err or "the ruleset could not be locked", info)
  end
  return entry
end

---The documents of a ruleset have to be made again: called BEFORE the first write of an operation (a step back that
---fails leaves files half changed), with the entry that will tell the result so `finish` gives it its own ruleset's
---catalog.
---@param ctx Rules.OpsCtx
---@param root string
---@param entry table
local function touch(ctx, root, entry)
  ctx.touched[root] = true
  ctx.owner[entry] = root
end

---A scan that sees what an operation before it wrote.
---@param ctx Rules.OpsCtx
---@return Rules.Contract.View|nil view
---@return table|nil entry
local function fresh(ctx)
  contract.clear_cache()
  local view, err = contract.view(ctx.opts)
  if not view then
    return nil, fail(ctx, err)
  end
  return view, nil
end

---A text with LF line ends (a CR LF pair is a line end, a lone CR stays a control character).
---@param text string
---@return string
local function lf(text)
  return (text:gsub("\r\n", "\n"))
end

---Validate a check or an agent hint given as data.
---@param value any
---@param what string
---@return string|nil why
local function check_data(value, what)
  if type(value) ~= "table" or (next(value) ~= nil and vim.islist(value)) then
    return what .. " must be an object"
  end
  local text, err = rule_edit.lua_value(value)
  if not text then
    return ("%s cannot be written: %s"):format(what, err)
  end
  if #text > 4000 then
    return what .. " is too long"
  end
  if what == "check" and type(value.type) ~= "string" then
    return "check needs a text `type`"
  end
  return nil
end

---@param text string
---@return string|nil why
local function check_one_line(text, what)
  if ops_lib.has_control(text) or text:find("\n", 1, true) then
    return what .. " must be one line without control characters"
  end
  return nil
end

local PLACE_FIELDS = {
  after = "string",
  before = "string",
  section = "string",
  layout = "string",
  first = "boolean",
  top = "boolean",
  nth = "integer",
  gap = "object",
}

local GAP_MAX = 100

---Whether `value` is a good value for the place field `key` (the door checks the type of a field of an operation; an
---entry of `places` is checked here).
---@param key string
---@param value any
---@return boolean
local function place_field_ok(key, value)
  local kind = PLACE_FIELDS[key]
  if kind == "string" or kind == "boolean" then
    return type(value) == kind and (key ~= "top" or value == true)
  elseif kind == "integer" then
    return type(value) == "number" and value == math.floor(value) and value >= 1 and value <= 999999
  elseif kind == "object" then
    return type(value) == "table" and (next(value) == nil or not vim.islist(value))
  end
  return false
end

---Why a `gap` is no `{ above = n, below = m }` (blank lines, 0 to GAP_MAX each).
---@param gap table
---@return string|nil why
local function gap_error(gap)
  for key, value in pairs(gap) do
    if key ~= "above" and key ~= "below" then
      return "gap has above and below, not " .. tostring(key):sub(1, 40)
    end
    if type(value) ~= "number" or value ~= math.floor(value) or value < 0 or value > GAP_MAX then
      return ("gap.%s must be a whole number from 0 to %d"):format(key, GAP_MAX)
    end
  end
  return nil
end

---The place of a placement request: where in which layout.
---@param op table
---@return table|nil where   { after?, before?, section?, first?, nth?, layout?, top?, gap? }
---@return string|nil why
local function placement(op)
  local n = (op.after and 1 or 0) + (op.before and 1 or 0) + (op.section and 1 or 0) + (op.top and 1 or 0)
  if n == 0 then
    if op.layout ~= nil or op.first ~= nil or op.nth ~= nil or op.gap ~= nil then
      return nil, "layout, first, nth and gap need a place"
    end
    return nil, nil
  end
  if n > 1 then
    return nil, "give one place: after, before, section or top"
  end
  if (op.section or op.top) and not op.layout then
    return nil, "section and top need the layout (its output path) that holds them"
  end
  if (op.after or op.before or op.top) and (op.first ~= nil or op.nth ~= nil) then
    return nil, "first and nth go with a section"
  end
  if op.gap ~= nil then
    local why = gap_error(op.gap)
    if why then
      return nil, why
    end
  end
  return {
    after = op.after,
    before = op.before,
    section = op.section,
    first = op.first,
    nth = op.nth,
    layout = op.layout,
    top = op.top,
    gap = op.gap,
  },
    nil
end

---The places of a reinstate: one given as fields, or `places` = `{ [layout output] = { after | before | section,
---first? | top } }` (what `retire` answers: every layout that held the rule).
---@param op table
---@return table[]|nil wheres   in the order of the layouts' outputs
---@return string|nil why
local function placements(op)
  if op.places == nil then
    local where, why = placement(op)
    return where and { where } or {}, why
  end
  if
    op.after
    or op.before
    or op.section
    or op.layout ~= nil
    or op.first ~= nil
    or op.top ~= nil
    or op.nth ~= nil
    or op.gap ~= nil
  then
    return nil, "places goes alone, without after, before, section, layout, first, nth, gap or top"
  end
  local outputs = vim.tbl_keys(op.places)
  table.sort(outputs)
  local out = {}
  for _, output in ipairs(outputs) do
    local one = op.places[output]
    if type(one) ~= "table" then
      return nil, "every entry of places must be an object"
    end
    for key, value in pairs(one) do
      if not (PLACE_FIELDS[key] and key ~= "layout" and place_field_ok(key, value)) then
        return nil, "an entry of places has after, before, section, first, nth, gap or top, not " .. tostring(key):sub(1, 40)
      end
    end
    local where, why = placement(vim.tbl_extend("force", one, { layout = output }))
    if not where then
      return nil, why or "an entry of places needs a place"
    end
    out[#out + 1] = where
  end
  return out, nil
end

---Put the token of `id` in the layouts at `where`. Changes `tx`, returns the output of the layout.
---@param ctx Rules.OpsCtx
---@param tx Rules.Tx
---@param root string
---@param id string
---@param where table
---@return string|nil output
---@return string|nil why
---@return "io"|nil kind   "io" when the layout could not be written (the place itself was fine)
local function place_in_layout(ctx, tx, root, id, where)
  local all = layouts_of(root)
  local target
  if where.after or where.before then
    local anchor = where.after or where.before
    for _, layout in ipairs(all) do
      -- a rule held in several layouts is the anchor of each: the layout that is named is the one
      if (where.layout == nil or layout.output == where.layout) and layout_edit.has(layout.text, anchor) then
        target = layout
        break
      end
    end
    if not target then
      return nil, ("no layout has {{rule %s}} to put it next to"):format(anchor)
    end
  else
    for _, layout in ipairs(all) do
      if layout.output == where.layout then
        target = layout
        break
      end
    end
    if not target then
      return nil, ("no layout makes the document %q"):format(where.layout)
    end
  end
  local new_text, why = layout_edit.place(target.text, id, where)
  if not new_text then
    return nil, why
  end
  if not ctx.dry then
    local ok, err = write_in(tx, target.path, new_text)
    if not ok then
      return nil, tostring(err), "io"
    end
  end
  return target.output, nil, nil
end

---Put the token of the rule of `op` at every place of `wheres`. The answer is `{ layout }` for one place given as
---fields, `{ layouts }` for `places`, `nil` for none; a refusal is the second value.
---@param ctx Rules.OpsCtx
---@param tx Rules.Tx
---@param root string
---@param op table
---@param wheres table[]
---@return table|nil placed
---@return string|nil why
---@return "io"|nil kind   "io" when a layout could not be written
local function place_all(ctx, tx, root, op, wheres)
  local outs = {}
  for _, where in ipairs(wheres) do
    local out, why, kind = place_in_layout(ctx, tx, root, op.id, where)
    if not out then
      return nil, tostring(why), kind
    end
    outs[#outs + 1] = out
  end
  if #outs == 0 then
    return nil, nil
  end
  return json.object(op.places ~= nil and { layouts = json.array(outs) } or { layout = outs[1] }), nil
end

---Where the token of `id` stands now, as a `place` that brings it back byte for byte (`layout_edit.where`): `{ layout,
---after }`, `{ layout, before }`, `{ layout, section, first?, nth? }` or `{ layout, top }`, with `gap` (the blank lines
---around it) where `place` would not write them on its own; `nil` when the layout does not hold it.
---@param layout Rules.Layout
---@param id string
---@return table|nil
local function old_place(layout, id)
  local where = layout_edit.where(layout.text, id)
  if not where then
    return nil
  end
  where.layout = layout.output
  return where
end

---The rule file of an id and what is known of it.
---@param ctx Rules.OpsCtx
---@param view Rules.Contract.View
---@param id string
---@return string|nil path
---@return table|nil entry   a refusal entry when nil
local function rule_file_of(ctx, view, id)
  local path = view.abs[id]
  if not path then
    return nil, fail(ctx, errors.fail("not_found", ("no rule with the id %s"):format(id)))
  end
  local summary = view.full[id]
  if summary.etag_scope ~= "rule" then
    return nil,
      refuse(
        "invalid_argument",
        ("%s lives in a document with many rules; migrate it to one file per rule first (scripts/ruleset.lua migrate)"):format(id)
      )
  end
  return path, nil
end

---@param current string
---@param if_match string|nil
---@return table|nil entry
local function conflict(current, if_match)
  if if_match == nil or if_match == current then
    return nil
  end
  return {
    ok = false,
    outcome = "conflict",
    error = {
      code = "conflict",
      message = "the file is not the version the caller saw",
      retryable = false,
      details = json.object({ expected = if_match, actual = current }),
    },
  }
end

---The warnings that go with a rule made in the ruleset `root`: the rules-vault it lies in is a git repository that is
---behind its upstream. Two machines that make a rule in one family without a pull in between make the same id, and
---the clash is found only when their commits meet (a duplicate id is a load error, so the CI of the vault turns red).
---Read only: what the last `git fetch` knows, no network, no pull, never a commit; silent without a vault, without git
---and without an upstream. A warning, not a refusal: the rule is made.
---@param ctx Rules.OpsCtx
---@param root string
---@return string[]|nil warnings
local function behind_warnings(ctx, root)
  local vault = require("rules.settings").resolve({ vault = ctx.opts.vault, project = ctx.opts.project }).vault
  if not (vault and vault.exists and vault.root) then
    return nil
  end
  -- by real path: a vault named by a link, a short Windows name or /var against /private/var is the same folder
  ---@param path string
  ---@return string
  local function real(path)
    return vim.fs.normalize(vim.uv.fs_realpath(path) or path)
  end
  if not contract.doc.relative(real(vault.root), real(root)) then
    return nil
  end
  local behind = require("rules.vault").behind(vault.root)
  if not behind or behind < 1 then
    return nil
  end
  return {
    (
      "the vault is %d commit(s) behind its upstream: pull before you make a rule (git pull in the vault), or another machine"
      .. " may have made the same id; a duplicate id fails the check"
    ):format(behind),
  }
end

-- ── new ─────────────────────────────────────────────────────────────────────────

---@param op table
---@param ctx Rules.OpsCtx
---@return table
local function do_new(op, ctx)
  if op.family == nil or op.title == nil or op.severity == nil then
    return refuse("invalid_argument", "new needs family, title and severity")
  end
  local family_why = M.family_error(op.family)
  if family_why then
    return refuse("invalid_argument", "family " .. family_why)
  end
  if not vim.tbl_contains(rule_edit.SEVERITIES, op.severity) then
    return refuse("invalid_argument", ("severity must be one of %s"):format(table.concat(rule_edit.SEVERITIES, ", ")))
  end
  local why = check_one_line(op.title, "title")
  if why then
    return refuse("invalid_argument", why)
  end
  if op.title == "" or ops_lib.too_long(op.title, M.MAX_TITLE) then
    return refuse("invalid_argument", ("title must be 1 to %d characters"):format(M.MAX_TITLE))
  end
  -- a text from a Windows clipboard or a CR LF file has CR LF line ends: those are line ends, not control characters
  local text_in = type(op.text) == "string" and lf(op.text) or op.text
  if text_in ~= nil then
    if ops_lib.has_control(text_in) then
      return refuse("invalid_argument", "text contains a control character")
    end
    if ops_lib.too_long(text_in, M.MAX_TEXT) then
      return refuse("payload_too_large", ("text is longer than %d characters"):format(M.MAX_TEXT))
    end
  end
  for _, key in ipairs({ "check", "agent" }) do
    if op[key] ~= nil then
      local bad = check_data(op[key], key)
      if bad then
        return refuse("invalid_argument", bad)
      end
    end
  end
  local where, wwhy = placement(op)
  if wwhy then
    return refuse("invalid_argument", wwhy)
  end
  local root, rwhy = ruleset(ctx, op.ruleset)
  if not root then
    return refuse("invalid_argument", rwhy or "no ruleset")
  end
  if not is_folder(root) then
    return refuse("invalid_argument", "the ruleset is a single file; new needs a ruleset folder")
  end

  local warnings = behind_warnings(ctx, root)

  return locked(ctx, root, function()
    local view, bad = fresh(ctx)
    if not view then
      return bad
    end
    local id = contract.next_free(view, op.family)
    if not id then
      return refuse("invalid_argument", ("the family %s has no id left (an id has at most 100 bytes)"):format(op.family))
    end
    local text, terr = rule_edit.render_new({
      id = id,
      severity = op.severity,
      title = op.title,
      text = text_in,
      check = op.check,
      agent = op.agent,
    })
    if not text then
      return refuse("invalid_argument", tostring(terr))
    end
    local entry = { ok = true, id = id, etag_after = etag.of(text), changed_ids = {} }
    if warnings then
      entry.warnings = json.array(warnings)
    end
    if ctx.dry then
      -- the placement is checked too: a dry run that says "yes" must not fail on the place
      entry.outcome = "would_create"
      if where then
        local out, pwhy = place_in_layout(ctx, new_tx(), root, id, where)
        if not out then
          return refuse("invalid_argument", tostring(pwhy))
        end
        entry.placed = json.object({ layout = out })
      end
      entry.etag_after = nil
      return entry
    end
    local path = ("%s/_rules/%s/%s.md"):format(root, op.family, id)
    local tx = new_tx()
    touch(ctx, root, entry)
    local ok, err = create_exclusive(path, text)
    if not ok then
      return fail(ctx, err == "exists" and errors.fail("conflict", ("the file of %s exists already"):format(id)) or err)
    end
    tx.created[#tx.created + 1] = path
    if where then
      local out, pwhy, pkind = place_in_layout(ctx, tx, root, id, where)
      if not out then
        local stop = stopped(ctx, tx, tostring(pwhy))
        -- a refused place is the caller's bad input; a layout that could not be written is an io failure
        if stop.error.code == "io" and pkind ~= "io" then
          stop.error.code = "invalid_argument"
        end
        return stop
      end
      entry.placed = json.object({ layout = out })
    end
    contract.clear_cache()
    entry.outcome = "created"
    entry.changed_ids = { id }
    entry.inverse = json.object({ op = "retire", id = id, reason = "undo of new", if_match = entry.etag_after })
    return entry
  end)
end

-- ── set ─────────────────────────────────────────────────────────────────────────

local SETTABLE = { severity = true, title = true, text = true, check = true, agent = true }

---@param op table
---@param ctx Rules.OpsCtx
---@return table
local function do_set(op, ctx)
  if op.id == nil or op.patch == nil then
    return refuse("invalid_argument", "set needs id and patch")
  end
  local patch = {}
  local count = 0
  for key, value in pairs(op.patch) do
    if not SETTABLE[key] then
      return refuse(
        "invalid_argument",
        "patch can change severity, title, text, check and agent, not " .. tostring(key):sub(1, 40)
      )
    end
    count = count + 1
    patch[key] = (key == "text" and type(value) == "string") and lf(value) or value
  end
  if count == 0 then
    return refuse("invalid_argument", "patch is empty")
  end
  if patch.severity ~= nil and not vim.tbl_contains(rule_edit.SEVERITIES, patch.severity) then
    return refuse("invalid_argument", ("severity must be one of %s"):format(table.concat(rule_edit.SEVERITIES, ", ")))
  end
  for _, key in ipairs({ "title", "text", "severity" }) do
    local value = patch[key]
    if value ~= nil then
      if type(value) ~= "string" then
        return refuse("invalid_argument", key .. " must be a text")
      end
      if ops_lib.has_control(value) then
        return refuse("invalid_argument", key .. " contains a control character")
      end
    end
  end
  if patch.title ~= nil then
    local why = check_one_line(patch.title, "title")
    if why or patch.title == "" or ops_lib.too_long(patch.title, M.MAX_TITLE) then
      return refuse("invalid_argument", why or ("title must be 1 to %d characters"):format(M.MAX_TITLE))
    end
  end
  if patch.text ~= nil and ops_lib.too_long(patch.text, M.MAX_TEXT) then
    return refuse("payload_too_large", ("text is longer than %d characters"):format(M.MAX_TEXT))
  end
  for _, key in ipairs({ "check", "agent" }) do
    if patch[key] ~= nil and patch[key] ~= vim.NIL then
      local bad = check_data(patch[key], key)
      if bad then
        return refuse("invalid_argument", bad)
      end
    end
  end

  local view0, bad0 = fresh(ctx)
  if not view0 then
    return bad0
  end
  local file0, refusal = rule_file_of(ctx, view0, op.id)
  if not file0 then
    return refusal
  end
  local root = ruleset_of(ctx, file0) or ctx.root

  return locked(ctx, root, function()
    local view, bad = fresh(ctx)
    if not view then
      return bad
    end
    local path, rbad = rule_file_of(ctx, view, op.id)
    if not path then
      return rbad
    end
    local before_bytes = read_bytes(path)
    if not before_bytes then
      return fail(ctx, errors.fail("io", "the file of the rule cannot be read"))
    end
    local current = etag.of(before_bytes)
    local clash = conflict(current, op.if_match)
    if clash then
      return clash
    end
    local summary = view.full[op.id]
    -- the values before, in the shape a `set` takes: what undoes the change
    local before = {}
    if patch.severity ~= nil then
      before.severity = summary.severity
    end
    if patch.title ~= nil then
      before.title = summary.title
    end
    if patch.text ~= nil then
      before.text = summary.text
    end
    for _, key in ipairs({ "check", "agent" }) do
      if patch[key] ~= nil then
        before[key] = summary[key] ~= nil and summary[key] or vim.NIL
      end
    end
    local new_text, why = rule_edit.apply(path, before_bytes, patch)
    if not new_text then
      return refuse("invalid_argument", tostring(why))
    end
    local entry = { ok = true, id = op.id, etag_before = current, changed_ids = {} }
    if new_text == before_bytes then
      entry.outcome = "unchanged"
      entry.etag_after = current
      return entry
    end
    if ctx.dry then
      entry.outcome = "would_change"
      entry.diff = json.object({ before = before_bytes, after = new_text })
      return entry
    end
    touch(ctx, root, entry)
    local ok, err = write_atomic(path, new_text)
    if not ok then
      return fail(ctx, errors.fail("io", tostring(err)))
    end
    contract.clear_cache()
    entry.outcome = "changed"
    entry.etag_after = etag.of(new_text)
    entry.changed_ids = { op.id }
    entry.before = json.object(before)
    entry.inverse = json.object({ op = "set", id = op.id, patch = json.object(before), if_match = entry.etag_after })
    return entry
  end)
end

-- ── retire / reinstate ──────────────────────────────────────────────────────────

---The frontmatter lines a retired rule's file gets, after `family:`.
---@param path_in_root string
---@param op table
---@param today string
---@return string[]
local function retired_lines(path_in_root, op, today)
  local out = { "status: retired", "retired: " .. today, "was: " .. path_in_root }
  if op.replaced_by then
    out[#out + 1] = "replaced_by: " .. op.replaced_by
  end
  if op.reason and op.reason ~= "" then
    out[#out + 1] = "reason: " .. op.reason
  end
  return out
end

---@param op table
---@param ctx Rules.OpsCtx
---@return table
local function do_retire(op, ctx)
  if op.id == nil then
    return refuse("invalid_argument", "retire needs id")
  end
  if op.reason ~= nil then
    local why = check_one_line(op.reason, "reason")
    if why or ops_lib.too_long(op.reason, M.MAX_REASON) then
      return refuse("invalid_argument", why or ("reason is longer than %d characters"):format(M.MAX_REASON))
    end
  end
  if op.replaced_by ~= nil and op.replaced_by == op.id then
    return refuse("invalid_argument", "a rule cannot replace itself")
  end
  local view0, bad0 = fresh(ctx)
  if not view0 then
    return bad0
  end
  local file0, refusal = rule_file_of(ctx, view0, op.id)
  if not file0 then
    return refusal
  end
  local root = ruleset_of(ctx, file0) or ctx.root
  if op.replaced_by ~= nil and not view0.abs[op.replaced_by] then
    return refuse("not_found", ("replaced_by names no loaded rule: %s"):format(op.replaced_by:sub(1, 60)))
  end

  return locked(ctx, root, function()
    local view, bad = fresh(ctx)
    if not view then
      return bad
    end
    local path, rbad = rule_file_of(ctx, view, op.id)
    if not path then
      return rbad
    end
    local bytes = read_bytes(path)
    if not bytes then
      return fail(ctx, errors.fail("io", "the file of the rule cannot be read"))
    end
    local current = etag.of(bytes)
    local clash = conflict(current, op.if_match)
    if clash then
      return clash
    end
    local family = view.full[op.id].family
    local normal = vim.fs.normalize(path)
    local rel = contract.doc.relative(root, normal) or (family .. "/" .. op.id .. ".md")
    local target = ("%s/_retired/%s/%s.md"):format(root, family, op.id)
    local today = ctx.today
    -- the retired file: the original with the facts of its retirement after the frontmatter's own lines
    local lines = vim.split(bytes, "\n", { plain = true })
    local eol = bytes:find("\r\n", 1, true) and "\r" or ""
    local close
    for i = 2, #lines do
      if lines[i]:gsub("%s+$", "") == "---" then
        close = i
        break
      end
    end
    if not close then
      return refuse("invalid_argument", "the file has no closed frontmatter")
    end
    local extra = retired_lines(rel, op, today)
    for i = #extra, 1, -1 do
      table.insert(lines, close, extra[i] .. eol)
    end
    local retired_text = table.concat(lines, "\n")

    -- which layouts hold the rule, and where: for the inverse and for taking it out
    local held = {}
    for _, layout in ipairs(layouts_of(root)) do
      if layout_edit.has(layout.text, op.id) then
        held[#held + 1] = layout
      end
    end

    local entry = { ok = true, id = op.id, etag_before = current, changed_ids = {} }
    if ctx.dry then
      entry.outcome = "would_retire"
      return entry
    end
    local tx = new_tx()
    touch(ctx, root, entry)
    local ok, err = create_exclusive(target, retired_text)
    if not ok then
      return fail(ctx, err == "exists" and errors.fail("conflict", ("%s is retired already"):format(op.id)) or err)
    end
    tx.created[#tx.created + 1] = target
    -- where the rule stood in every layout that held it: `reinstate` puts it back into each of them
    local places = {}
    for _, layout in ipairs(held) do
      local one = old_place(layout, op.id) or {}
      one.layout = nil
      places[layout.output] = json.object(one)
      local new_text, why = layout_edit.remove(layout.text, op.id)
      if not new_text then
        return stopped(ctx, tx, tostring(why))
      end
      local wrote, werr = write_in(tx, layout.path, new_text)
      if not wrote then
        return stopped(ctx, tx, tostring(werr))
      end
    end
    tx.deleted[path] = bytes
    local removed, rerr = os.remove(path)
    if not removed then
      tx.deleted[path] = nil
      return stopped(ctx, tx, "the file of the rule could not be removed: " .. tostring(rerr))
    end
    contract.clear_cache()
    entry.outcome = "retired"
    entry.changed_ids = { op.id }
    entry.inverse = json.object({
      op = "reinstate",
      id = op.id,
      places = next(places) and json.object(places) or nil,
    })
    return entry
  end)
end

---@param op table
---@param ctx Rules.OpsCtx
---@return table
local function do_reinstate(op, ctx)
  if op.id == nil then
    return refuse("invalid_argument", "reinstate needs id")
  end
  local wheres, wwhy = placements(op)
  if wwhy or not wheres then
    return refuse("invalid_argument", wwhy)
  end
  local view0, bad0 = fresh(ctx)
  if not view0 then
    return bad0
  end
  local found
  for _, retired in ipairs(view0.retired) do
    if retired.id == op.id then
      found = retired
      break
    end
  end
  if not found then
    return fail(ctx, errors.fail("not_found", ("no retired rule with the id %s"):format(op.id)))
  end
  if view0.abs[op.id] then
    return refuse("invalid_argument", ("%s is loaded again already"):format(op.id))
  end
  -- which ruleset holds it: the one with the file
  local source, root
  for _, path in ipairs(ctx.paths) do
    local candidate = ("%s/_retired/%s/%s.md"):format(path, found.family, op.id)
    if vim.uv.fs_stat(candidate) then
      source, root = candidate, path
      break
    end
  end
  if not source or not root then
    return fail(ctx, errors.fail("not_found", "the file of the retired rule is gone"))
  end

  return locked(ctx, root, function()
    local bytes = read_bytes(source)
    if not bytes then
      return fail(ctx, errors.fail("io", "the file of the retired rule cannot be read"))
    end
    local lines = vim.split(bytes, "\n", { plain = true })
    local was
    local kept = {}
    local in_front, ended = false, false
    for i, line in ipairs(lines) do
      local bare = line:gsub("\r$", "")
      if i == 1 and bare:gsub("%s+$", "") == "---" then
        in_front = true
        kept[#kept + 1] = line
      elseif in_front and not ended then
        if bare:gsub("%s+$", "") == "---" then
          ended = true
          kept[#kept + 1] = line
        else
          local key, value = bare:match("^([%w_]+):%s*(.-)%s*$")
          if key == "was" then
            was = value
          end
          if not (key == "status" or key == "retired" or key == "was" or key == "replaced_by" or key == "reason") then
            kept[#kept + 1] = line
          end
        end
      else
        kept[#kept + 1] = line
      end
    end
    local rel = was
    if not rel or rel == "" or rel:find("..", 1, true) or rel:match("^[/\\]") or rel:match("^%a:") or not rel:match("%.md$") then
      rel = ("_rules/%s/%s.md"):format(found.family, op.id)
    end
    local target = root .. "/" .. rel
    local entry = { ok = true, id = op.id, changed_ids = {} }
    local text = table.concat(kept, "\n")
    local rule, rerrs = parser.parse_rule_text(target, (text:gsub("\r\n", "\n")))
    if not rule or #rerrs > 0 then
      return refuse("invalid_argument", "the retired file would not read as a rule: " .. tostring((rerrs or {})[1] or "unknown"))
    end
    if ctx.dry then
      -- the target and the placement are checked too: a dry run that says "yes" must not fail on them
      if vim.uv.fs_stat(target) then
        return fail(ctx, errors.fail("conflict", "a file is where the rule would go back to"))
      end
      entry.outcome = "would_reinstate"
      local placed, pwhy = place_all(ctx, new_tx(), root, op, wheres)
      if pwhy then
        return refuse("invalid_argument", pwhy)
      end
      entry.placed = placed
      return entry
    end
    local tx = new_tx()
    touch(ctx, root, entry)
    local ok, err = create_exclusive(target, text)
    if not ok then
      return fail(ctx, err == "exists" and errors.fail("conflict", "a file is where the rule would go back to") or err)
    end
    tx.created[#tx.created + 1] = target
    local placed, pwhy, pkind = place_all(ctx, tx, root, op, wheres)
    if pwhy then
      local stop = stopped(ctx, tx, pwhy)
      if stop.error.code == "io" and pkind ~= "io" then
        stop.error.code = "invalid_argument"
      end
      return stop
    end
    entry.placed = placed
    tx.deleted[source] = bytes
    local removed, rerr = os.remove(source)
    if not removed then
      tx.deleted[source] = nil
      return stopped(ctx, tx, "the retired file could not be removed: " .. tostring(rerr))
    end
    contract.clear_cache()
    entry.outcome = "reinstated"
    entry.changed_ids = { op.id }
    entry.etag_after = etag.of(text)
    entry.inverse = json.object({ op = "retire", id = op.id, if_match = entry.etag_after })
    return entry
  end)
end

-- ── move ────────────────────────────────────────────────────────────────────────

---Whether two layout texts hold the same lines in the same order, blank lines apart: taking a token out collapses a
---doubled blank line, so a rule put back at its own place need not give back the same text.
---@param a string
---@param b string
---@return boolean
local function same_order(a, b)
  local function content(text)
    local out = {}
    for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
      local bare = line:gsub("%s+$", "")
      if bare ~= "" then
        out[#out + 1] = bare
      end
    end
    return out
  end
  return vim.deep_equal(content(a), content(b))
end

---@param op table
---@param ctx Rules.OpsCtx
---@return table
local function do_move(op, ctx)
  if op.id == nil then
    return refuse("invalid_argument", "move needs id")
  end
  local where, wwhy = placement(op)
  if wwhy then
    return refuse("invalid_argument", wwhy)
  end
  if not where then
    return refuse("invalid_argument", "move needs a place: after, before or section")
  end
  if where.after == op.id or where.before == op.id then
    return refuse("invalid_argument", "a rule cannot be put next to itself")
  end
  local view0, bad0 = fresh(ctx)
  if not view0 then
    return bad0
  end
  local file0 = view0.abs[op.id]
  if not file0 then
    return fail(ctx, errors.fail("not_found", ("no rule with the id %s"):format(op.id)))
  end
  local root = ruleset_of(ctx, file0) or ctx.root

  return locked(ctx, root, function()
    local all = layouts_of(root)
    -- the layout the rule is taken from: of those that hold it, the one that is named (a move inside it), else the
    -- first that also holds the anchor, else the first
    local home
    local anchor0 = where.after or where.before
    for _, layout in ipairs(all) do
      if layout_edit.has(layout.text, op.id) then
        if where.layout ~= nil and layout.output == where.layout then
          home = layout
          break
        end
        if not home then
          home = layout
        end
        if where.layout == nil and anchor0 and layout_edit.has(layout.text, anchor0) then
          home = layout
          break
        end
      end
    end
    local entry = { ok = true, id = op.id, changed_ids = {} }
    local old = home and old_place(home, op.id) or nil
    local tx = new_tx()
    local source_text = home and home.text or nil
    if home then
      local removed, why = layout_edit.remove(home.text, op.id)
      if not removed then
        return refuse("invalid_argument", tostring(why))
      end
      source_text = removed
    end
    -- put it in, in the layout text as it is after the removal (the same file may be both)
    local target
    if where.after or where.before then
      local anchor = where.after or where.before
      for _, layout in ipairs(all) do
        local text = (home and layout.path == home.path) and source_text or layout.text
        if (where.layout == nil or layout.output == where.layout) and layout_edit.has(text, anchor) then
          target = layout
          break
        end
      end
      if not target then
        return refuse("invalid_argument", ("no layout has {{rule %s}} to put it next to"):format(anchor))
      end
    else
      for _, layout in ipairs(all) do
        if layout.output == where.layout then
          target = layout
          break
        end
      end
      if not target then
        return refuse("invalid_argument", ("no layout makes the document %q"):format(where.layout))
      end
    end
    local base = (home and target.path == home.path) and source_text or target.text
    local placed_text, why = layout_edit.place(base, op.id, where)
    if not placed_text then
      return refuse("invalid_argument", tostring(why))
    end
    if home and target.path == home.path and same_order(placed_text, home.text) then
      entry.outcome = "unchanged"
      return entry
    end
    if ctx.dry then
      entry.outcome = "would_move"
      return entry
    end
    touch(ctx, root, entry)
    if home and target.path ~= home.path then
      local ok, err = write_in(tx, home.path, source_text)
      if not ok then
        return stopped(ctx, tx, tostring(err))
      end
    end
    local ok, err = write_in(tx, target.path, placed_text)
    if not ok then
      return stopped(ctx, tx, tostring(err))
    end
    contract.clear_cache()
    entry.outcome = "moved"
    entry.changed_ids = { op.id }
    entry.placed = json.object({ layout = target.output })
    if old then
      entry.inverse = json.object({
        op = "move",
        id = op.id,
        layout = old.layout,
        after = old.after,
        before = old.before,
        section = old.section,
        first = old.first,
        nth = old.nth,
        top = old.top,
        gap = old.gap and json.object(old.gap) or nil,
      })
    end
    return entry
  end)
end

-- ── the door ────────────────────────────────────────────────────────────────────

---@param ... table
---@return table
local function fields(...)
  local out = {}
  for _, tbl in ipairs({ ... }) do
    for key, kind in pairs(tbl) do
      out[key] = kind
    end
  end
  return out
end

door = ops_lib.make({
  doc = contract.doc,
  order = { "new", "set", "retire", "reinstate", "move" },
  ops = {
    new = {
      fields = fields(PLACE_FIELDS, {
        family = "string",
        title = "string",
        severity = "string",
        text = "string",
        check = "object",
        agent = "object",
        ruleset = "string",
      }),
      run = do_new,
    },
    set = {
      fields = { id = "string", patch = "object", if_match = "string" },
      run = do_set,
    },
    retire = {
      fields = { id = "string", replaced_by = "string", reason = "string", if_match = "string" },
      run = do_retire,
    },
    reinstate = {
      fields = fields(PLACE_FIELDS, { id = "string", places = "object" }),
      run = do_reinstate,
    },
    move = {
      fields = fields(PLACE_FIELDS, { id = "string" }),
      run = do_move,
    },
  },
  context = function(params, opts)
    local paths, names, settings_err = contract.rulesets(opts)
    if settings_err then
      return nil, errors.fail("invalid_argument", settings_err)
    end
    if #paths == 0 then
      return nil, errors.fail("not_found", "no ruleset is configured (rulesets is empty)")
    end
    return {
      root = paths[1],
      paths = paths,
      names = names,
      opts = {
        rulesets = opts and opts.rulesets,
        gates = opts and opts.gates,
        vault = opts and opts.vault,
        project = opts and opts.project,
      },
      dry = params.dry_run == true,
      touched = {},
      owner = {},
      today = (opts and opts.today) or os.date("%Y-%m-%d"),
    }
  end,
  finish = function(ctx, results)
    if ctx.dry then
      return
    end
    local roots = vim.tbl_keys(ctx.touched)
    table.sort(roots)
    local by_root = {}
    -- every ruleset that had a write attempted, also one whose step back failed (the files are half changed)
    for _, root in ipairs(roots) do
      local built, problems = catalog.build(root)
      local summary = { written = 0, errors = #problems }
      for _, result in ipairs(built) do
        if result.status == "written" then
          summary.written = summary.written + 1
        elseif result.status == "error" then
          summary.errors = summary.errors + 1
        end
      end
      by_root[root] = summary
    end
    contract.clear_cache()
    for _, entry in ipairs(results) do
      local summary = by_root[ctx.owner[entry]]
      if summary and entry.ok and entry.changed_ids and #entry.changed_ids > 0 then
        entry.catalog = json.object({ written = summary.written, errors = summary.errors })
      end
    end
  end,
})

---The layouts of a ruleset folder (the `output` path each one is the order of, and its text): where a rule can be
---placed. Reads, writes nothing; the editor completes `--to=` from it.
---@param root string
---@return Rules.Layout[]
function M.layouts(root)
  return layouts_of(root)
end

---The method entry for `rules.api`.
---@return table
function M.method()
  return door.method()
end

---Run a request directly (the `run` of a `contract.api` method).
---@param params table
---@param opts table|nil
---@return table|nil doc
---@return Lib.Contract.Error|nil err
function M.run(params, opts)
  return door.run(params, opts or {})
end

return M
