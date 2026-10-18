---@module 'rules.ruleset_ops'
---@brief Rulesets on the contract: the operations `create_ruleset`, `archive_ruleset` and `restore_ruleset` of
--- `rules-ops/1`. They change the VAULT (which rulesets it holds), not a ruleset's rules.
---@description
--- A ruleset is a folder under `<vault>/rulesets/<name>/` (`_rules/`, `_layouts/`); the vault's own `.rules.json` may
--- list the rulesets it offers, otherwise every folder there is one. These operations name a ruleset by its folder name
--- and work in the vault the engine was started with (`$RULES_VAULT`, `setup({ vault })`); no path is ever taken from
--- the request and none is echoed.
---
---  - `create_ruleset` { name } makes `rulesets/<name>/_rules/.gitkeep` and `_layouts/.gitkeep`, and adds the ruleset to
---    the `rulesets` list of the vault's `.rules.json` when that file has one that does not offer it. An existing
---    folder of that name (in any letter case) is a `conflict`. `inverse`: `archive_ruleset`.
---  - `archive_ruleset` { name } MOVES `rulesets/<name>` to `archive/rulesets/<name>` (outside `rulesets/`, so nothing
---    loads it) and takes it out of the `.rules.json` list. It never deletes. The last ruleset of the vault is not
---    archived (an engine without a ruleset has nothing to answer), and a name already in the archive is a `conflict`.
---    `inverse`: `restore_ruleset`.
---  - `restore_ruleset` { name } moves `archive/rulesets/<name>` back and lists it again. `inverse`: `archive_ruleset`.
---
--- The `.rules.json` is edited as text: only the `rulesets` list changes, the rest of the file stays byte for byte
--- (its keys, its `gates`, its layout). One writer at a time over the vault (a hidden lock file beside the vault's
--- `.rules.json`, removed again). An operation that fails half way takes its step back.

local create_exclusive = require("lib.nvim.fs.create_exclusive")
local with_lock = require("lib.nvim.fs.with_lock")
local write_atomic = require("lib.nvim.fs.write.atomic")
local read = require("lib.nvim.fs.read")
local json = require("lib.nvim.json.canonical")

local contract = require("rules.contract")
local scaffold = require("rules.vault_scaffold")
local vault_ops = require("rules.vault_ops")
local vault = require("rules.vault")

local M = {}

---The operations of this module, in the order of the door.
M.NAMES = { "create_ruleset", "archive_ruleset", "restore_ruleset" }

---Where an archived ruleset lies, relative to the vault: outside `rulesets/`, so no scan reads it.
M.ARCHIVE = "archive/rulesets"

local uv = vim.uv or vim.loop

-- ── the list of `.rules.json` as text ───────────────────────────────────────────

---The end (exclusive) of the JSON value that starts at `i`, skipping strings with their escapes.
---@param text string
---@param i integer
---@return integer
local function value_end(text, i)
  local c = text:sub(i, i)
  if c == '"' then
    local j = i + 1
    while j <= #text do
      local d = text:sub(j, j)
      if d == "\\" then
        j = j + 2
      elseif d == '"' then
        return j + 1
      else
        j = j + 1
      end
    end
    return #text + 1
  end
  if c == "[" or c == "{" then
    local depth, j = 0, i
    while j <= #text do
      local d = text:sub(j, j)
      if d == '"' then
        j = value_end(text, j)
      else
        if d == "[" or d == "{" then
          depth = depth + 1
        elseif d == "]" or d == "}" then
          depth = depth - 1
        end
        j = j + 1
        if depth == 0 then
          return j
        end
      end
    end
    return #text + 1
  end
  local j = i
  while j <= #text and not text:sub(j, j):match("[,%]}%s]") do
    j = j + 1
  end
  return j
end

---@param text string
---@param i integer
---@return integer
local function skip_ws(text, i)
  local _, e = text:find("^%s*", i)
  return (e or i - 1) + 1
end

---@class Rules.RulesetList
---@field close integer           position of the `]`
---@field items { s: integer, e: integer, value: any }[]  the elements: first byte, last byte, decoded value

---Where the `rulesets` list of a `.rules.json` text is: `nil` when the file has none, `false` and a reason when the text
---is not what the engine reads.
---@param text string
---@return Rules.RulesetList|nil|false list
---@return string|nil why
local function scan_list(text)
  local ok, decoded = pcall(vim.json.decode, text)
  if not ok or type(decoded) ~= "table" or vim.islist(decoded) and #decoded > 0 then
    return false, "its .rules.json cannot be read"
  end
  local i = skip_ws(text, 1)
  if text:sub(i, i) ~= "{" then
    return false, "its .rules.json is not an object"
  end
  i = i + 1
  while true do
    i = skip_ws(text, i)
    local c = text:sub(i, i)
    if c == "}" or c == "" then
      return nil
    end
    if c == "," then
      i = i + 1
    elseif c == '"' then
      local key_end = value_end(text, i)
      local key = vim.json.decode(text:sub(i, key_end - 1))
      i = skip_ws(text, key_end)
      if text:sub(i, i) ~= ":" then
        return false, "its .rules.json cannot be read"
      end
      i = skip_ws(text, i + 1)
      local stop = value_end(text, i)
      if key == "rulesets" then
        if text:sub(i, i) ~= "[" then
          return false, "the rulesets of its .rules.json are not a list"
        end
        local list = { close = stop - 1, items = {} }
        local j = i + 1
        while true do
          j = skip_ws(text, j)
          local d = text:sub(j, j)
          if d == "]" or d == "" then
            break
          end
          if d == "," then
            j = j + 1
          else
            local e = value_end(text, j)
            local dec_ok, value = pcall(vim.json.decode, text:sub(j, e - 1))
            list.items[#list.items + 1] = { s = j, e = e - 1, value = dec_ok and value or nil }
            j = e
          end
        end
        return list
      end
      i = stop
    else
      return false, "its .rules.json cannot be read"
    end
  end
end

---Whether a `rulesets` entry names the folder `<root>/rulesets/<name>`.
---@param root string
---@param entry any
---@param name string
---@return boolean
local function names(root, entry, name)
  if type(entry) ~= "string" then
    return false
  end
  if entry == "@vault/" .. name then
    return true
  end
  local absolute = entry:match("^/") or entry:match("^%a:")
  local path = vim.fs.normalize(absolute and entry or (root .. "/" .. entry))
  return vault_ops.fold(path) == vault_ops.fold(vim.fs.normalize(root .. "/rulesets/" .. name))
end

---The text with `rulesets/<name>` added to the list (no list: unchanged), or the reason it cannot be.
---@param root string
---@param text string
---@param name string
---@return string|nil text
---@return string|nil why
local function list_add(root, text, name)
  local list, why = scan_list(text)
  if list == false then
    return nil, why
  end
  if list == nil then
    return text, nil
  end
  for _, item in ipairs(list.items) do
    if names(root, item.value, name) then
      return text, nil
    end
  end
  local entry = vim.json.encode("rulesets/" .. name)
  local out
  if #list.items == 0 then
    out = text:sub(1, list.close - 1) .. entry .. text:sub(list.close)
  else
    local last = list.items[#list.items]
    out = text:sub(1, last.e) .. ", " .. entry .. text:sub(last.e + 1)
  end
  return out, nil
end

---The text without the entries that name `rulesets/<name>` (no list: unchanged).
---@param root string
---@param text string
---@param name string
---@return string|nil text
---@return string|nil why
local function list_remove(root, text, name)
  for _ = 1, 100 do
    local list, why = scan_list(text)
    if list == false then
      return nil, why
    end
    if list == nil then
      return text, nil
    end
    local at
    for index, item in ipairs(list.items) do
      if names(root, item.value, name) then
        at = index
        break
      end
    end
    if not at then
      return text, nil
    end
    local item = list.items[at]
    if at < #list.items then
      -- up to the start of the next element: the comma and the space go with it
      text = text:sub(1, item.s - 1) .. text:sub(list.items[at + 1].s)
    elseif at > 1 then
      text = text:sub(1, list.items[at - 1].e) .. text:sub(item.e + 1)
    else
      text = text:sub(1, item.s - 1) .. text:sub(item.e + 1)
    end
  end
  return nil, "its .rules.json lists the ruleset too often"
end

-- ── the vault ───────────────────────────────────────────────────────────────────

---@param path string
---@return table|nil
local function lstat(path)
  return uv.fs_lstat(path)
end

---The vault, or the refusal that says there is none.
---@param ctx Rules.OpsCtx
---@param door table
---@return string|nil root
---@return table|nil refusal
local function vault_root(ctx, door)
  local root, why = vault.root({ vault = ctx.opts.vault, project = ctx.opts.project })
  if not root then
    return nil, door.refuse("not_found", why or "no vault is configured")
  end
  return root, nil
end

---The name of a ruleset, checked.
---@param op table
---@param door table
---@return string|nil name
---@return table|nil refusal
local function name_of(op, door)
  if op.name == nil then
    return nil, door.refuse("invalid_argument", op.op .. " needs name")
  end
  local ok, why = scaffold.check_name(op.name)
  if not ok then
    return nil, door.refuse("invalid_argument", why or "not a usable ruleset name")
  end
  return op.name, nil
end

---The folder of a ruleset of the vault with this name, in the letter case it has on disk (`nil` if there is none).
---@param dir string  `<vault>/rulesets` or `<vault>/archive/rulesets`
---@param name string
---@return string|nil folder  the real name
local function folder_named(dir, name)
  local fold = vault_ops.fold
  local handle = uv.fs_scandir(dir)
  while handle do
    local entry = uv.fs_scandir_next(handle)
    if not entry then
      break
    end
    if fold(entry) == fold(name) then
      return entry
    end
  end
  return nil
end

---Run `fn` with the vault locked: one writer at a time.
---@param ctx Rules.OpsCtx
---@param door table
---@param root string
---@param fn fun(): table
---@return table
local function locked(ctx, door, root, fn)
  local entry, err, info = with_lock(root .. "/.rules-vault-ops", fn, { wait_ms = 2000 })
  if entry == nil then
    return door.failure(ctx.root, err or "the vault could not be locked", info)
  end
  return entry
end

---Make `.rules.json` say `text`, remembering the old bytes. Returns what to do to take it back.
---@param file string
---@param text string
---@return function|nil undo
---@return string|nil why
local function rewrite(file, text)
  local before = read(file)
  if before == nil then
    return nil, "its .rules.json could not be read"
  end
  if before == text then
    return function() end, nil
  end
  local ok, err = write_atomic(file, text)
  if not ok then
    return nil, "its .rules.json could not be written: " .. tostring(err)
  end
  return function()
    write_atomic(file, before)
  end, nil
end

---The text of the vault's `.rules.json` after `edit`, `nil` text and no reason when the file is not there.
---@param root string
---@param edit fun(root: string, text: string, name: string): string|nil, string|nil
---@param name string
---@return string|nil text
---@return string|nil why
---@return boolean exists
local function edited_list(root, edit, name)
  local text = read(root .. "/.rules.json")
  if text == nil then
    return nil, nil, false
  end
  local out, why = edit(root, text, name)
  return out, why, true
end

---@param entry table
---@param name string
---@param inverse string
---@param outcome string
---@return table
local function done(entry, name, inverse, outcome)
  entry.outcome = outcome
  entry.inverse = json.object({ op = inverse, name = name })
  contract.clear_cache()
  return entry
end

-- ── the operations ──────────────────────────────────────────────────────────────

---@param op table
---@param ctx Rules.OpsCtx
---@param door table
---@return table
function M.create(op, ctx, door)
  local name, bad = name_of(op, door)
  if not name then
    return bad
  end
  local root, none = vault_root(ctx, door)
  if not root then
    return none
  end
  return locked(ctx, door, root, function()
    local dir = root .. "/rulesets"
    if folder_named(dir, name) or lstat(dir .. "/" .. name) then
      return door.refuse("conflict", ("a ruleset called %q is there already"):format(name))
    end
    local files = { ("rulesets/%s/_rules/.gitkeep"):format(name), ("rulesets/%s/_layouts/.gitkeep"):format(name) }
    local layout_err = scaffold.check_layout(root, files)
    if layout_err then
      return door.refuse("invalid_argument", layout_err)
    end
    local list_text, why, has_file = edited_list(root, list_add, name)
    if has_file and list_text == nil then
      return door.refuse("invalid_argument", why or "its .rules.json cannot be used")
    end
    local entry = { ok = true, ruleset = name, changed_ids = {} }
    if ctx.dry then
      entry.outcome = "would_create"
      return entry
    end
    local made = {}
    local function undo()
      for index = #made, 1, -1 do
        os.remove(made[index])
      end
      uv.fs_rmdir(dir .. "/" .. name .. "/_rules")
      uv.fs_rmdir(dir .. "/" .. name .. "/_layouts")
      uv.fs_rmdir(dir .. "/" .. name)
    end
    for _, rel in ipairs(files) do
      local path = root .. "/" .. rel
      vim.fn.mkdir(vim.fs.dirname(path), "p")
      local ok, err = create_exclusive(path, "")
      if not ok then
        undo()
        return door.refuse("io", "the ruleset could not be made: " .. tostring(err))
      end
      made[#made + 1] = path
    end
    if has_file then
      local back, rewrite_why = rewrite(root .. "/.rules.json", list_text)
      if not back then
        undo()
        return door.refuse("io", rewrite_why or "its .rules.json could not be written")
      end
    end
    return done(entry, name, "archive_ruleset", "created")
  end)
end

---Move `from` to `to`, making the folder above it.
---@param from string
---@param to string
---@return boolean ok
---@return string|nil err
local function move(from, to)
  vim.fn.mkdir(vim.fs.dirname(to), "p")
  local ok, err = uv.fs_rename(from, to)
  if not ok then
    return false, tostring(err)
  end
  return true, nil
end

---@param op table
---@param ctx Rules.OpsCtx
---@param door table
---@return table
function M.archive(op, ctx, door)
  local name, bad = name_of(op, door)
  if not name then
    return bad
  end
  local root, none = vault_root(ctx, door)
  if not root then
    return none
  end
  return locked(ctx, door, root, function()
    local real = folder_named(root .. "/rulesets", name)
    if not real then
      return door.refuse("not_found", ("the vault has no ruleset called %q"):format(name))
    end
    local offered = vault.rulesets({ vault = root, project = ctx.opts.project })
    if #offered <= 1 then
      return door.refuse("invalid_argument", "the last ruleset of the vault is not archived")
    end
    local from = root .. "/rulesets/" .. real
    local to = root .. "/" .. M.ARCHIVE .. "/" .. real
    if folder_named(root .. "/" .. M.ARCHIVE, real) or lstat(to) then
      return door.refuse("conflict", ("the archive holds a ruleset called %q already"):format(name))
    end
    local layout_err = scaffold.check_layout(root, { M.ARCHIVE .. "/" .. real .. "/_rules/.gitkeep" })
    if layout_err then
      return door.refuse("invalid_argument", layout_err)
    end
    local list_text, why, has_file = edited_list(root, list_remove, real)
    if has_file and list_text == nil then
      return door.refuse("invalid_argument", why or "its .rules.json cannot be used")
    end
    local entry = { ok = true, ruleset = real, changed_ids = {} }
    if ctx.dry then
      entry.outcome = "would_archive"
      return entry
    end
    local moved, err = move(from, to)
    if not moved then
      return door.refuse("io", "the ruleset could not be moved: " .. tostring(err))
    end
    if has_file then
      local back, rewrite_why = rewrite(root .. "/.rules.json", list_text)
      if not back then
        move(to, from)
        return door.refuse("io", rewrite_why or "its .rules.json could not be written")
      end
    end
    return done(entry, real, "restore_ruleset", "archived")
  end)
end

---@param op table
---@param ctx Rules.OpsCtx
---@param door table
---@return table
function M.restore(op, ctx, door)
  local name, bad = name_of(op, door)
  if not name then
    return bad
  end
  local root, none = vault_root(ctx, door)
  if not root then
    return none
  end
  return locked(ctx, door, root, function()
    local real = folder_named(root .. "/" .. M.ARCHIVE, name)
    if not real then
      return door.refuse("not_found", ("the archive holds no ruleset called %q"):format(name))
    end
    local from = root .. "/" .. M.ARCHIVE .. "/" .. real
    local to = root .. "/rulesets/" .. real
    if folder_named(root .. "/rulesets", real) or lstat(to) then
      return door.refuse("conflict", ("a ruleset called %q is there already"):format(name))
    end
    local list_text, why, has_file = edited_list(root, list_add, real)
    if has_file and list_text == nil then
      return door.refuse("invalid_argument", why or "its .rules.json cannot be used")
    end
    local entry = { ok = true, ruleset = real, changed_ids = {} }
    if ctx.dry then
      entry.outcome = "would_restore"
      return entry
    end
    local moved, err = move(from, to)
    if not moved then
      return door.refuse("io", "the ruleset could not be moved: " .. tostring(err))
    end
    if has_file then
      local back, rewrite_why = rewrite(root .. "/.rules.json", list_text)
      if not back then
        move(to, from)
        return door.refuse("io", rewrite_why or "its .rules.json could not be written")
      end
    end
    return done(entry, real, "archive_ruleset", "restored")
  end)
end

return M
