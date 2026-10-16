---@module 'rules.waiver_ops'
---@brief Waivers on the contract: the operations `waive`, `renew`, `remove` of `rules-ops/1` and the document
--- `rules.waivers` of `rules-export/1`.
---@description
--- A waiver lives in the CHECKED PROJECT (`<project>/.rules-waivers.json`, `rules.engine.waivers`), not in the rulesets
--- or the vault: the rulesets say what is wrong, the project says what it has accepted. So these operations name a
--- project (`project`, a folder; default the configured project) and do not take the lock of a ruleset: the file has
--- its own (`lib.nvim.fs.with_lock`, a hidden `.rules-waivers.json.lock` beside it), and the rules are not touched,
--- so no catalog is made again.
---
---  - `waive` { id, reason, expires?, paths?, project?, if_match? } adds the waiver of a LOADED rule (an id no ruleset
---    has is `invalid_argument`; a waiver for an id that is gone can still be read, renewed and removed). A waiver
---    that is there already is `invalid_argument` (renew or remove it), the same one again is `unchanged`.
---    `inverse`: `remove`.
---  - `renew` { id, expires | no_expiry, reason?, project?, if_match? } gives a waiver a new last day (or none) and
---    optionally a new reason; the paths stay. A waiver that is not there is `not_found`. `inverse`: `renew` back.
---  - `remove` { id, project?, if_match? } drops the waiver (`not_found` if there is none). `inverse`: `waive` with
---    the values it had.
---
--- `if_match` is the etag of the waivers FILE (a project without one has the etag of an empty file). Every write is
--- canonical (sorted keys, two spaces, LF, final newline; a waiver with only a reason stays in the short form), so the
--- file is written again whole: an entry nobody touched keeps its meaning but may change its layout. `dry_run`
--- answers with the file before and after (`diff`) and writes nothing.
---
--- A date in the past is accepted with a warning, not refused: an expired waiver is what `renew` is for, and the
--- `inverse` of a `renew` or a `remove` of such a waiver has to be able to put it back.
---
--- Not a path of this machine in any answer: the project is never echoed, and neither is the `inverse` told it (send
--- the same `project` again; `if_match` stops a replay against another folder).

local json = require("lib.nvim.json.canonical")
local etag = require("lib.nvim.fs.etag")
local ops_lib = require("lib.nvim.contract.ops")
local errors = require("lib.nvim.contract.errors")
local with_lock = require("lib.nvim.fs.with_lock")
local write_atomic = require("lib.nvim.fs.write.atomic")

local contract = require("rules.contract")
local waivers = require("rules.engine.waivers")

local M = {}

--- Paths that differ only in case are one folder on Windows and (by default) on macOS.
local CASE_INSENSITIVE = vim.fn.has("win32") == 1 or vim.fn.has("mac") == 1

--- The extra field types of the door (`paths`).
M.TYPES = {
  text_list = {
    label = "a list of text",
    is = function(value)
      if type(value) ~= "table" or not vim.islist(value) then
        return false
      end
      for _, v in ipairs(value) do
        if type(v) ~= "string" then
          return false
        end
      end
      return true
    end,
  },
}

-- ── the project ─────────────────────────────────────────────────────────────────

---@param path string
---@return string|nil real  the real path with `/`, nil when there is none
local function real_of(path)
  local real = vim.uv.fs_realpath(path)
  if not real then
    return nil
  end
  return (vim.fs.normalize(real):gsub("/+$", ""))
end

---How two real paths relate: the same folder, the second inside the first, or neither.
---@param base string
---@param path string
---@return "same"|"inside"|nil
local function relation(base, path)
  local b = base:gsub("/+$", "")
  local p = path:gsub("/+$", "")
  if CASE_INSENSITIVE then
    b, p = b:lower(), p:lower()
  end
  if p == b then
    return "same"
  end
  if p:sub(1, #b + 1) == b .. "/" then
    return "inside"
  end
  return nil
end

--- The project folder a request names, checked: a real folder, inside the configured project when there is one, and
--- not inside a ruleset (a waiver belongs to the project that is checked, not to the rulesets that check it) unless it is
--- the configured project itself. A given path has no `..` and no control character; a relative one starts at the
--- configured project. The answer is the real path.
---@param given string|nil  the request's `project`
---@param opts Rules.Contract.Opts|nil
---@param ruleset_paths string[]
---@return string|nil dir
---@return Lib.Contract.Error|nil err  without any path
function M.resolve_project(given, opts, ruleset_paths)
  local configured = opts and opts.project
  if configured == "" then
    configured = nil
  end
  local text = given
  if text == nil then
    text = configured
  end
  if type(text) ~= "string" or text == "" then
    return nil,
      errors.fail("invalid_argument", "there is no project: give `project` (a folder), or run with a configured project")
  end
  local dir = text
  if given ~= nil then
    if ops_lib.has_control(given) then
      return nil, errors.fail("invalid_argument", "project must be a folder path without control characters")
    end
    local slashed = given:gsub("\\", "/")
    for segment in (slashed .. "/"):gmatch("(.-)/") do
      if segment == ".." then
        return nil, errors.fail("invalid_argument", "project must not contain .. (name the folder itself)")
      end
    end
    local absolute = slashed:sub(1, 1) == "/" or slashed:match("^%a:") ~= nil
    if not absolute then
      if not configured then
        return nil, errors.fail("invalid_argument", "a relative project needs a configured project to start from")
      end
      dir = configured .. "/" .. given
    end
  end
  local real = real_of(dir)
  if not real or vim.fn.isdirectory(real) == 0 then
    return nil, errors.fail("not_found", "the project is not a folder that exists")
  end
  local real_configured = configured and real_of(configured)
  if given ~= nil and configured then
    if not real_configured or not relation(real_configured, real) then
      return nil, errors.fail("invalid_argument", "project must be the configured project or a folder inside it")
    end
  end
  local is_configured = real_configured ~= nil and relation(real_configured, real) == "same"
  if not is_configured then
    for _, ruleset in ipairs(ruleset_paths) do
      local real_ruleset = real_of(ruleset)
      if real_ruleset and relation(real_ruleset, real) then
        return nil,
          errors.fail(
            "invalid_argument",
            "project is inside a ruleset folder: a waiver belongs to the project that is checked, not to a ruleset"
          )
      end
    end
  end
  return real, nil
end

-- ── the file ────────────────────────────────────────────────────────────────────

---@param path string
---@return string|nil bytes
local function read_bytes(path)
  local fh = io.open(path, "rb")
  if not fh then
    return nil
  end
  local text = fh:read("*a")
  fh:close()
  return text
end

---The waivers file of a project as it is now.
---@param path string
---@param read_only? boolean  true: a link is followed, as the engine does (only a write refuses it)
---@return { bytes: string|nil, etag: string, entries: Rules.WaiverEntries }|nil state  bytes is nil when there is no file
---@return Lib.Contract.Error|nil err  without any path
local function read_state(path, read_only)
  local stat = vim.uv.fs_lstat(path)
  if not stat then
    return { bytes = nil, etag = etag.of(""), entries = {} }, nil
  end
  if stat.type == "link" then
    if not read_only then
      return nil,
        errors.fail(
          "forbidden",
          waivers.FILE .. " is a link: edit the file it points to by hand, the engine does not write through a link"
        )
    end
    -- the refusal is for the write (it would replace the link); the engine reads through the link, so does a read
    stat = vim.uv.fs_stat(path)
    if not stat then
      return nil, errors.fail("invalid_argument", waivers.FILE .. " is a link that leads nowhere")
    end
  end
  if stat.type ~= "file" then
    return nil, errors.fail("invalid_argument", waivers.FILE .. " is not a file")
  end
  local bytes = read_bytes(path)
  if not bytes then
    return nil, errors.fail("io", waivers.FILE .. " could not be read")
  end
  local entries, err = waivers.parse(bytes, waivers.FILE)
  if not entries then
    return nil, errors.fail("invalid_argument", "the waivers file cannot be used: " .. tostring(err))
  end
  return { bytes = bytes, etag = etag.of(bytes), entries = entries }, nil
end

---The entry of a request whose etag is not the file's.
---@param current string
---@param if_match string|nil
---@return table|nil entry
function M.conflict(current, if_match)
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

-- ── the operations ──────────────────────────────────────────────────────────────

---@param entry Rules.Waiver
---@return table
local function values_of(entry)
  return json.object({
    reason = entry.reason,
    expires = entry.expires,
    paths = entry.paths and json.array(vim.deepcopy(entry.paths)) or nil,
  })
end

---Run `work` on the waivers file of the request's project, under its lock.
---@param op table
---@param ctx Rules.OpsCtx
---@param door table
---@param work fun(state: table, dir: string): table
---@return table entry
local function with_file(op, ctx, door, work)
  local dir, perr = M.resolve_project(op.project, ctx.opts, ctx.paths)
  if not dir then
    return door.refuse(perr.code, perr.message)
  end
  local path = waivers.path(dir)
  local entry, _, info = with_lock(path, function()
    local state, err = read_state(path)
    if not state then
      return door.refuse(err.code, err.message)
    end
    local clash = M.conflict(state.etag, op.if_match)
    if clash then
      return clash
    end
    state.path = path
    return work(state, dir)
  end, { wait_ms = 2000 })
  if entry == nil then
    -- the text of a lock failure names the project: only the code is told
    local code = info and info.code or "io"
    local message = code == "locked" and "the waivers file is being written by another process; ask again"
      or "the waivers file could not be locked"
    return { ok = false, outcome = "failed", error = errors.fail(code, message, info and info.retryable == true) }
  end
  return entry
end

---Write the entries of `state` (or, in a dry run, show what would be written) and finish the answer.
---@param state table
---@param ctx Rules.OpsCtx
---@param door table
---@param entry table  the answer so far (`id`, ...)
---@param names { done: string, would: string }
---@param inverse fun(etag_after: string): table
---@return table
local function commit(state, ctx, door, entry, names, inverse)
  local text = waivers.encode(state.entries)
  entry.etag_before = state.etag
  if ctx.dry then
    entry.outcome = names.would
    entry.diff = json.object({ before = state.bytes or "", after = text })
    return entry
  end
  local ok = write_atomic(state.path, text)
  if not ok then
    return door.refuse("io", "the waivers file could not be written")
  end
  entry.outcome = names.done
  entry.etag_after = etag.of(text)
  entry.changed_ids = { entry.id }
  entry.inverse = inverse(entry.etag_after)
  return entry
end

---The answer of a request that changes nothing.
---@param state table
---@param id string
---@return table
local function unchanged(state, id)
  return { ok = true, id = id, outcome = "unchanged", etag_before = state.etag, etag_after = state.etag, changed_ids = {} }
end

---@param ctx Rules.OpsCtx
---@param expires string|nil
---@return string[]|nil warnings
local function past_warning(ctx, expires)
  if expires and expires < ctx.today then
    return { ("expires is before today (%s): the waiver is expired and suppresses nothing"):format(ctx.today) }
  end
  return nil
end

---@param value string
---@param what string
---@return string|nil why
local function text_error(value, what)
  if ops_lib.has_control(value) then
    return what .. " contains a control character"
  end
  return nil
end

---@param op table
---@param ctx Rules.OpsCtx
---@param door table
---@return table
function M.waive(op, ctx, door)
  if op.id == nil or op.reason == nil then
    return door.refuse("invalid_argument", "waive needs id and reason")
  end
  local id_why = waivers.id_error(op.id)
  if id_why then
    return door.refuse("invalid_argument", id_why)
  end
  local entry, why = waivers.entry(op.id, { reason = op.reason, expires = op.expires, paths = op.paths })
  if not entry then
    return door.refuse("invalid_argument", why or "the waiver cannot be used")
  end
  why = text_error(op.reason, "reason") or (op.paths and text_error(table.concat(op.paths, "\n"), "paths"))
  if why then
    return door.refuse("invalid_argument", why)
  end
  if vim.trim(op.reason) == "" then
    return door.refuse("invalid_argument", "reason must say something")
  end
  local view, verr = contract.view(ctx.opts)
  if not view then
    return door.failure(ctx.root, verr)
  end
  if not view.full[op.id] then
    return door.refuse("invalid_argument", ("no loaded rule has the id %s: a waiver needs a rule it can waive"):format(op.id))
  end
  return with_file(op, ctx, door, function(state)
    local old = state.entries[op.id]
    if old then
      if vim.deep_equal(old, entry) then
        return unchanged(state, op.id)
      end
      return door.refuse(
        "invalid_argument",
        ("%s is waived already: renew it to change the expiry or the reason, or remove it first"):format(op.id)
      )
    end
    if vim.tbl_count(state.entries) >= waivers.MAX_WAIVERS then
      return door.refuse(
        "payload_too_large",
        ("the file holds %d waivers already, the most it takes"):format(waivers.MAX_WAIVERS)
      )
    end
    state.entries[op.id] = entry
    local answer = { ok = true, id = op.id, changed_ids = {} }
    local warnings = past_warning(ctx, entry.expires)
    if warnings then
      answer.warnings = json.array(warnings)
    end
    return commit(state, ctx, door, answer, { done = "waived", would = "would_waive" }, function(after)
      return json.object({ op = "remove", id = op.id, if_match = after })
    end)
  end)
end

---@param op table
---@param ctx Rules.OpsCtx
---@param door table
---@return table
function M.renew(op, ctx, door)
  if op.id == nil then
    return door.refuse("invalid_argument", "renew needs id")
  end
  local id_why = waivers.id_error(op.id)
  if id_why then
    return door.refuse("invalid_argument", id_why)
  end
  if (op.expires == nil) == (op.no_expiry ~= true) then
    return door.refuse("invalid_argument", "renew needs expires (a new last day) or no_expiry=true, not both")
  end
  if op.no_expiry == false then
    return door.refuse("invalid_argument", "no_expiry is true or left out")
  end
  if op.expires ~= nil and not waivers.valid_date(op.expires) then
    return door.refuse("invalid_argument", "expires must be a calendar date in the form YYYY-MM-DD")
  end
  if op.reason ~= nil then
    local why = waivers.reason_error(op.reason) or text_error(op.reason, "reason")
    if why then
      return door.refuse("invalid_argument", "reason " .. why)
    end
    if vim.trim(op.reason) == "" then
      return door.refuse("invalid_argument", "reason must say something")
    end
  end
  return with_file(op, ctx, door, function(state)
    local old = state.entries[op.id]
    if not old then
      return door.refuse("not_found", ("no waiver for %s"):format(op.id))
    end
    local new = vim.deepcopy(old)
    new.expires = op.expires
    if op.reason ~= nil then
      new.reason = op.reason
    end
    if vim.deep_equal(old, new) then
      return unchanged(state, op.id)
    end
    state.entries[op.id] = new
    local before = old.expires and { expires = old.expires } or { no_expiry = true }
    if op.reason ~= nil and op.reason ~= old.reason then
      before.reason = old.reason
    end
    local answer = { ok = true, id = op.id, changed_ids = {}, before = json.object(before) }
    local warnings = past_warning(ctx, new.expires)
    if warnings then
      answer.warnings = json.array(warnings)
    end
    return commit(state, ctx, door, answer, { done = "renewed", would = "would_renew" }, function(after)
      return json.object({
        op = "renew",
        id = op.id,
        expires = before.expires,
        no_expiry = before.no_expiry,
        reason = before.reason,
        if_match = after,
      })
    end)
  end)
end

---@param op table
---@param ctx Rules.OpsCtx
---@param door table
---@return table
function M.remove(op, ctx, door)
  if op.id == nil then
    return door.refuse("invalid_argument", "remove needs id")
  end
  local id_why = waivers.id_error(op.id)
  if id_why then
    return door.refuse("invalid_argument", id_why)
  end
  return with_file(op, ctx, door, function(state)
    local old = state.entries[op.id]
    if not old then
      return door.refuse("not_found", ("no waiver for %s"):format(op.id))
    end
    state.entries[op.id] = nil
    local answer = { ok = true, id = op.id, changed_ids = {}, before = values_of(old) }
    return commit(state, ctx, door, answer, { done = "removed", would = "would_remove" }, function(after)
      return json.object({
        op = "waive",
        id = op.id,
        reason = old.reason,
        expires = old.expires,
        paths = old.paths and json.array(vim.deepcopy(old.paths)) or nil,
        if_match = after,
      })
    end)
  end)
end

-- ── the document ────────────────────────────────────────────────────────────────

--- `rules.waivers`: the waivers of a project, each with whether it is expired (on `today`) and whether a loaded rule
--- has its id. A waivers file that exists and cannot be used is an error, never an empty list.
---@param params { project?: string }
---@param opts Rules.Contract.Opts|nil
---@return table|nil doc
---@return Lib.Contract.Error|nil err
function M.document(params, opts)
  params = params or {}
  local view, verr = contract.view(opts)
  if not view then
    return nil, verr
  end
  local today, terr = waivers.today(opts and opts.today)
  if not today then
    return nil, errors.fail("invalid_argument", terr)
  end
  local dir, perr = M.resolve_project(params.project, opts, view.paths)
  if not dir then
    return nil, perr
  end
  local state, serr = read_state(waivers.path(dir), true)
  if not state then
    return nil, serr
  end
  local ids = vim.tbl_keys(state.entries)
  table.sort(ids, json.bytes_less)
  local items, expired, unknown = {}, 0, 0
  for _, id in ipairs(ids) do
    local entry = state.entries[id]
    local item = values_of(entry)
    item.id = id
    item.expired = waivers.is_expired(entry, today)
    item.known = view.full[id] ~= nil
    expired = expired + (item.expired and 1 or 0)
    unknown = unknown + (item.known and 0 or 1)
    items[#items + 1] = item
  end
  local d = contract.doc
  local doc = d.head(d.kind("waivers"), view.paths[1])
  doc.today = today
  doc.etag = state.etag
  doc.exists = state.bytes ~= nil
  doc.counts = json.object({ total = #items, expired = expired, unknown = unknown })
  doc.items = json.array(items)
  return d.seal(doc, d.rev_of({ "rules\t" .. view.rev, "waivers\t" .. state.etag, "today\t" .. today })), nil
end

return M
