---@module 'rules.ops'
---@brief The write door of `rules-ops/1`: new, set, retire, reinstate, move.
---@description
--- Built on `lib.nvim.contract.ops` (the shape check of the whole request first, one entry per operation, `dry_run`,
--- `client_op_id`, no path of this machine in an entry). What an operation DOES is here.
---
--- One rule is one file (`<ruleset>/_rules/<FAMILY>/<ID>.md`), so a rule is changed, created or retired without
--- touching another rule's text; where it stands in a generated document is the layout's business (`{{rule ID}}`).
---
---  - `new` { family, title, severity, text?, check?, agent?, after? | before? | (layout, section, first?), ruleset? }
---    creates the file with the next free id (loaded and retired ids count: an id is never given twice) under the
---    ruleset's lock, and puts the rule in a layout when a place is given. `inverse`: `retire`.
---  - `set` { id, patch = { severity?, title?, text?, check?, agent? }, if_match? } changes parts of the rule's file by
---    editing lines (`rules.engine.rule_edit`); `if_match` is the etag the client saw, a changed file is a
---    `conflict` with `expected` and `actual`. `null` in `check`/`agent` removes it. `inverse`: `set` back.
---  - `retire` { id, replaced_by?, reason?, if_match? } moves the file to `<ruleset>/_retired/<FAMILY>/<ID>.md`
---    (the loader does not read that folder, the id stays taken) and takes its place in the layouts out.
---    `inverse`: `reinstate`.
---  - `reinstate` { id, place? } brings a retired rule back, to where it came from. `inverse`: `retire`.
---  - `move` { id, after? | before? | (layout, section, first?) } moves the `{{rule ID}}` line of a rule, within a
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

---@class Rules.OpsCtx
---@field root string               the first ruleset (what an error hides)
---@field paths string[]
---@field names table<string, string>
---@field opts Rules.Contract.Opts
---@field dry boolean
---@field touched table<string, true>   rulesets whose documents have to be made again

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

---The place of a placement request: where in which layout.
---@param op table
---@return table|nil where   { after?, before?, section?, first?, layout? }
---@return string|nil why
local function placement(op)
  local n = (op.after and 1 or 0) + (op.before and 1 or 0) + (op.section and 1 or 0)
  if n == 0 then
    if op.layout ~= nil or op.first ~= nil then
      return nil, "layout and first need a section"
    end
    return nil, nil
  end
  if n > 1 then
    return nil, "give one place: after, before or section"
  end
  if op.section and not op.layout then
    return nil, "section needs the layout (its output path) that holds it"
  end
  if (op.after or op.before) and (op.first ~= nil) then
    return nil, "first goes with a section"
  end
  return { after = op.after, before = op.before, section = op.section, first = op.first, layout = op.layout }, nil
end

---Put the token of `id` in the layouts at `where`. Changes `tx`, returns the output of the layout.
---@param ctx Rules.OpsCtx
---@param tx Rules.Tx
---@param root string
---@param id string
---@param where table
---@return string|nil output
---@return string|nil why
local function place_in_layout(ctx, tx, root, id, where)
  local all = layouts_of(root)
  local target
  if where.after or where.before then
    local anchor = where.after or where.before
    for _, layout in ipairs(all) do
      if layout_edit.has(layout.text, anchor) then
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
      return nil, tostring(err)
    end
  end
  return target.output, nil
end

---Where the token of `id` stands now, as a `place` that brings it back: `{ layout, after }`, `{ layout, before }` or
---`{ layout, section, first }`; `nil` when it cannot be described.
---@param layout Rules.Layout
---@param id string
---@return table|nil
local function old_place(layout, id)
  local at = layout_edit.locate(layout.text, id)
  if not at then
    return nil
  end
  if at.prev then
    return { layout = layout.output, after = at.prev }
  elseif at.section then
    return { layout = layout.output, section = at.section, first = true }
  end
  return nil
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

-- ── new ─────────────────────────────────────────────────────────────────────────

---@param op table
---@param ctx Rules.OpsCtx
---@return table
local function do_new(op, ctx)
  if op.family == nil or op.title == nil or op.severity == nil then
    return refuse("invalid_argument", "new needs family, title and severity")
  end
  if not op.family:match("^%a+$") or #op.family > M.FAMILY_MAX then
    return refuse("invalid_argument", ("family must be letters only, at most %d"):format(M.FAMILY_MAX))
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
  if op.text ~= nil then
    if ops_lib.has_control(op.text) then
      return refuse("invalid_argument", "text contains a control character")
    end
    if ops_lib.too_long(op.text, M.MAX_TEXT) then
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

  return locked(ctx, root, function()
    local view, bad = fresh(ctx)
    if not view then
      return bad
    end
    local id = contract.next_free(view, op.family)
    local text, terr = rule_edit.render_new({
      id = id,
      severity = op.severity,
      title = op.title,
      text = op.text,
      check = op.check,
      agent = op.agent,
    })
    if not text then
      return refuse("invalid_argument", tostring(terr))
    end
    local entry = { ok = true, id = id, etag_after = etag.of(text), changed_ids = {} }
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
    local ok, err = create_exclusive(path, text)
    if not ok then
      return fail(ctx, err == "exists" and errors.fail("conflict", ("the file of %s exists already"):format(id)) or err)
    end
    tx.created[#tx.created + 1] = path
    if where then
      local out, pwhy = place_in_layout(ctx, tx, root, id, where)
      if not out then
        local stop = stopped(ctx, tx, tostring(pwhy))
        if stop.error.code == "io" then
          stop.error.code = "invalid_argument"
        end
        return stop
      end
      entry.placed = json.object({ layout = out })
    end
    ctx.touched[root] = true
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
    patch[key] = value
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
    local ok, err = write_atomic(path, new_text)
    if not ok then
      return fail(ctx, errors.fail("io", tostring(err)))
    end
    ctx.touched[root] = true
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
    local ok, err = create_exclusive(target, retired_text)
    if not ok then
      return fail(ctx, err == "exists" and errors.fail("conflict", ("%s is retired already"):format(op.id)) or err)
    end
    tx.created[#tx.created + 1] = target
    local place
    for _, layout in ipairs(held) do
      place = place or old_place(layout, op.id)
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
    ctx.touched[root] = true
    contract.clear_cache()
    entry.outcome = "retired"
    entry.changed_ids = { op.id }
    entry.inverse = json.object({
      op = "reinstate",
      id = op.id,
      layout = place and place.layout or nil,
      after = place and place.after or nil,
      section = place and place.section or nil,
      first = place and place.first or nil,
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
  local where, wwhy = placement(op)
  if wwhy then
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
      if where then
        local out, pwhy = place_in_layout(ctx, new_tx(), root, op.id, where)
        if not out then
          return refuse("invalid_argument", tostring(pwhy))
        end
        entry.placed = json.object({ layout = out })
      end
      return entry
    end
    local tx = new_tx()
    local ok, err = create_exclusive(target, text)
    if not ok then
      return fail(ctx, err == "exists" and errors.fail("conflict", "a file is where the rule would go back to") or err)
    end
    tx.created[#tx.created + 1] = target
    if where then
      local out, pwhy = place_in_layout(ctx, tx, root, op.id, where)
      if not out then
        local stop = stopped(ctx, tx, tostring(pwhy))
        if stop.error.code == "io" then
          stop.error.code = "invalid_argument"
        end
        return stop
      end
      entry.placed = json.object({ layout = out })
    end
    tx.deleted[source] = bytes
    local removed, rerr = os.remove(source)
    if not removed then
      tx.deleted[source] = nil
      return stopped(ctx, tx, "the retired file could not be removed: " .. tostring(rerr))
    end
    ctx.touched[root] = true
    contract.clear_cache()
    entry.outcome = "reinstated"
    entry.changed_ids = { op.id }
    entry.etag_after = etag.of(text)
    entry.inverse = json.object({ op = "retire", id = op.id, if_match = entry.etag_after })
    return entry
  end)
end

-- ── move ────────────────────────────────────────────────────────────────────────

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
    local home
    for _, layout in ipairs(all) do
      if layout_edit.has(layout.text, op.id) then
        home = layout
        break
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
        if layout_edit.has(text, anchor) then
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
    if home and target.path == home.path and placed_text == home.text then
      entry.outcome = "unchanged"
      return entry
    end
    if ctx.dry then
      entry.outcome = "would_move"
      return entry
    end
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
    ctx.touched[root] = true
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
        section = old.section,
        first = old.first,
      })
    end
    return entry
  end)
end

-- ── the door ────────────────────────────────────────────────────────────────────

local PLACE_FIELDS = {
  after = "string",
  before = "string",
  section = "string",
  layout = "string",
  first = "boolean",
}

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
      fields = fields(PLACE_FIELDS, { id = "string" }),
      run = do_reinstate,
    },
    move = {
      fields = fields(PLACE_FIELDS, { id = "string" }),
      run = do_move,
    },
  },
  context = function(params, opts)
    local paths, names = contract.rulesets(opts)
    if #paths == 0 then
      return nil, errors.fail("not_found", "no ruleset is configured (rulesets is empty)")
    end
    return {
      root = paths[1],
      paths = paths,
      names = names,
      opts = { rulesets = opts and opts.rulesets, gates = opts and opts.gates },
      dry = params.dry_run == true,
      touched = {},
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
      if entry.ok and entry.changed_ids and #entry.changed_ids > 0 then
        local any = next(by_root)
        if any then
          local summary = by_root[any]
          entry.catalog = json.object({ written = summary.written, errors = summary.errors })
        end
      end
    end
  end,
})

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
