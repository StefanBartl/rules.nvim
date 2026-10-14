---@module 'rules.vault_ops'
---@brief What `:RulesVault` knows about the vault: which ruleset, rule id or family a word means, which paths belong to it,
---@brief the rules as a tree, the text of a path or a link. No notifications, no windows, no writes.
---@description
--- The editor command (`rules.ui.vault_cmd`) asks this module for everything it needs to point at; the same functions
--- can serve a script. The vault itself is `rules.vault` (where it is, which rulesets it offers); the rules in it are
--- the scan of the engine (`rules.contract.view`), taken over exactly those rulesets, so what the command says is the
--- vault's and not whatever `setup({ rulesets })` happens to load.
---
--- Key responsibilities:
---  - `context`: the vault and its rulesets, or the reason there is none (`none` is a normal state, `broken` is not)
---  - `resolve`: a word is a ruleset, a rule id, a family or a part (in that order, one reading each)
---  - `subjects` / `search_roots`: the files and folders a verb works on
---  - `tree_lines`: the rules of a ruleset, family by family, retired ones marked
---  - `display_path`, `markdown_link`, `cdx_prompt`: the text a path becomes
---
--- Paths are compared by their real path (a temporary folder behind a link, a Windows short name) and a name is folded
--- to one case only where the file system does that itself (Windows, macOS): `lua` and `Lua` are two rulesets on Linux.
---
--- Not its job: notifications, pickers, the clipboard (`rules.ui.vault_cmd`), the scaffold of a new vault
--- (`rules.vault_scaffold`).

local M = {}

---The parts of a ruleset a command can point at.
---@type string[]
M.PARTS = { "rules", "layouts", "catalogs", "all" }

---The default part: the rules are what the command is named for.
M.DEFAULT_PART = "rules"

---What each part is, for the help and the completion.
---@type table<string, string>
M.PART_DESC = {
  rules = "the rule files (_rules/), else the ruleset folder when it keeps its rules in documents",
  layouts = "the layouts (_layouts/) that say how the reading documents are made",
  catalogs = "the generated reading documents (the output of the layouts)",
  all = "the whole ruleset folder",
}

---Paths that differ only in case are one folder on Windows and (by default) on macOS.
M.CASE_BLIND = vim.fn.has("win32") == 1 or vim.fn.has("mac") == 1

---@param word any
---@return boolean
function M.is_part(word)
  return type(word) == "string" and vim.tbl_contains(M.PARTS, word)
end

---The text folded to one case where the file system does that, as it is otherwise.
---@param text string
---@return string
function M.fold(text)
  if not M.CASE_BLIND then
    return text
  end
  return text:find("[\128-\255]") and vim.fn.tolower(text) or text:lower()
end

---Whether two paths are one folder or file, compared by their real path.
---@param a string
---@param b string
---@return boolean
function M.same_path(a, b)
  local is_subpath = require("lib.nvim.fs.is_subpath")
  local opts = { ignore_case = M.CASE_BLIND }
  return is_subpath(a, b, opts) and is_subpath(b, a, opts)
end

---Whether `path` lies in `dir` (or is it), compared by real path.
---@param path string
---@param dir string
---@return boolean
function M.inside(path, dir)
  return require("lib.nvim.fs.is_subpath")(path, dir, { ignore_case = M.CASE_BLIND })
end

-- ── the vault ────────────────────────────────────────────────────────────────────────

---@class Rules.Vault.Ruleset
---@field name string  the name a document gives it (its folder name)
---@field dir string   absolute, `/`-separated

---@class Rules.Vault.Ctx
---@field root string
---@field source string|nil  where the vault was named
---@field rulesets Rules.Vault.Ruleset[]
---@field view Rules.Contract.View|nil
---@field view_err string|nil
---@field index Rules.Vault.Index|nil

---The vault and its rulesets (`rules.vault`). Without a vault, the kind of the answer is told: `none` (nothing names
---one: a normal state) or `broken` (it is named, the folder is not there, or a file that names it cannot be used).
---@param opts? Rules.Vault.Opts
---@return Rules.Vault.Ctx|nil ctx
---@return "none"|"broken"|nil kind
---@return string|nil message  from `rules.vault`, with the place the setting came from
function M.context(opts)
  local vault = require("rules.vault")
  local root, message = vault.root(opts)
  if not root then
    return nil, vault.is_none(message) and "none" or "broken", message
  end
  local dirs = vault.rulesets(opts)
  -- the paths as the engine spells them, and the name each goes by in a document (the folder name)
  local paths, names = require("rules.contract").rulesets({ rulesets = dirs })
  local rulesets = {}
  for _, path in ipairs(paths) do
    rulesets[#rulesets + 1] = { name = names[path], dir = path }
  end
  return { root = root, source = vault.source(opts), rulesets = rulesets }, nil, nil
end

---The names of the rulesets.
---@param ctx Rules.Vault.Ctx
---@return string[]
function M.ruleset_names(ctx)
  local out = {}
  for _, rs in ipairs(ctx.rulesets) do
    out[#out + 1] = rs.name
  end
  return out
end

---The ruleset a word names: the exact name, else (only where the file system ignores case) the same name in another case.
---@param ctx Rules.Vault.Ctx
---@param word string
---@return Rules.Vault.Ruleset|nil
function M.match_ruleset(ctx, word)
  for _, rs in ipairs(ctx.rulesets) do
    if rs.name == word then
      return rs
    end
  end
  if M.CASE_BLIND then
    local folded = M.fold(word)
    for _, rs in ipairs(ctx.rulesets) do
      if M.fold(rs.name) == folded then
        return rs
      end
    end
  end
  return nil
end

---The ruleset a file or folder lies in (by real path), or nil.
---@param ctx Rules.Vault.Ctx
---@param path string
---@return Rules.Vault.Ruleset|nil
function M.ruleset_of_path(ctx, path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local best
  for _, rs in ipairs(ctx.rulesets) do
    if M.inside(path, rs.dir) and (not best or #rs.dir > #best.dir) then
      best = rs
    end
  end
  return best
end

---The ruleset of the current buffer (or of the working directory when the buffer is no file).
---@param ctx Rules.Vault.Ctx
---@param bufnr? integer
---@return Rules.Vault.Ruleset|nil
function M.ruleset_of_buffer(ctx, bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr or 0)
  if name == "" then
    name = vim.fn.getcwd()
  elseif name:match("^%a[%w+.-]*://") or vim.bo[bufnr or 0].buftype ~= "" then
    return nil
  end
  return M.ruleset_of_path(ctx, vim.fn.fnamemodify(name, ":p"))
end

-- ── the rules ────────────────────────────────────────────────────────────────────────

---@class Rules.Vault.Entry
---@field id string
---@field family string
---@field file string
---@field line integer|nil
---@field retired boolean
---@field ruleset Rules.Vault.Ruleset|nil
---@field severity string|nil
---@field title string|nil
---@field replaced_by string|nil

---@class Rules.Vault.Index
---@field by_id table<string, Rules.Vault.Entry>
---@field by_family table<string, Rules.Vault.Entry[]>  sorted by number
---@field families string[]                              sorted

---The ruleset a source name (`<ruleset name>/<path>`, how a document names a file) belongs to.
---@param ctx Rules.Vault.Ctx
---@param source string
---@return Rules.Vault.Ruleset|nil
local function ruleset_of_source(ctx, source)
  local best
  for _, rs in ipairs(ctx.rulesets) do
    if (source == rs.name or source:sub(1, #rs.name + 1) == rs.name .. "/") and (not best or #rs.name > #best.name) then
      best = rs
    end
  end
  return best
end

---The scan of the vault's rulesets, kept on the context.
---@param ctx Rules.Vault.Ctx
---@return Rules.Contract.View|nil view
---@return string|nil err
function M.view(ctx)
  if ctx.view then
    return ctx.view, nil
  end
  if ctx.view_err then
    return nil, ctx.view_err
  end
  if #ctx.rulesets == 0 then
    ctx.view_err = ("the vault has no ruleset yet: nothing is under %s/rulesets/ (:RulesVault create <dir> <name>)"):format(
      ctx.root
    )
    return nil, ctx.view_err
  end
  local dirs = {}
  for _, rs in ipairs(ctx.rulesets) do
    dirs[#dirs + 1] = rs.dir
  end
  local view, err = require("rules.contract").view({ rulesets = dirs })
  if not view then
    ctx.view_err = (err and err.message) or "the rulesets of the vault could not be read"
    return nil, ctx.view_err
  end
  ctx.view = view
  return view, nil
end

---@param id string
---@return integer
local function number_of(id)
  return tonumber(id:match("(%d+)$")) or 0
end

---@param list Rules.Vault.Entry[]
local function sort_entries(list)
  table.sort(list, function(a, b)
    local na, nb = number_of(a.id), number_of(b.id)
    if na ~= nb then
      return na < nb
    end
    return a.id < b.id
  end)
end

---Every rule of the vault by id and by family, the retired ones included (their ids stay taken).
---@param ctx Rules.Vault.Ctx
---@return Rules.Vault.Index|nil index
---@return string|nil err
function M.index(ctx)
  if ctx.index then
    return ctx.index, nil
  end
  local view, err = M.view(ctx)
  if not view then
    return nil, err
  end
  ---@type Rules.Vault.Index
  local index = { by_id = {}, by_family = {}, families = {} }
  ---@param entry Rules.Vault.Entry
  local function add(entry)
    index.by_id[entry.id] = index.by_id[entry.id] or entry
    local list = index.by_family[entry.family]
    if not list then
      list = {}
      index.by_family[entry.family] = list
      index.families[#index.families + 1] = entry.family
    end
    list[#list + 1] = entry
  end
  for _, rule in ipairs(view.rules) do
    add({
      id = rule.id,
      family = rule.family,
      file = view.abs[rule.id],
      line = rule.line,
      retired = false,
      ruleset = ruleset_of_source(ctx, rule.source),
      severity = rule.severity,
      title = (rule.title:gsub("^`" .. vim.pesc(rule.id) .. "`%s*—%s*", "")),
    })
  end
  for _, rule in ipairs(view.retired) do
    local rs = ruleset_of_source(ctx, rule.source)
    -- the source is `<ruleset name>/<path>`: the file is the same path below the ruleset folder
    local file = rs and (rs.dir .. "/" .. rule.source:sub(#rs.name + 2)) or nil
    if file then
      add({
        id = rule.id,
        family = rule.family,
        file = file,
        retired = true,
        ruleset = rs,
        replaced_by = rule.replaced_by,
      })
    end
  end
  table.sort(index.families)
  for _, list in pairs(index.by_family) do
    sort_entries(list)
  end
  ctx.index = index
  return index, nil
end

-- ── words to a target ────────────────────────────────────────────────────────────────

---@class Rules.Vault.Target
---@field kind "ruleset"|"id"|"family"|"none"  `none`: no ruleset was named (the caller settles it)
---@field part string                       one of `PARTS`
---@field part_given boolean                the user named a part
---@field name string|nil                   the ruleset, id or family
---@field ruleset Rules.Vault.Ruleset|nil   for `ruleset`
---@field entry Rules.Vault.Entry|nil       for `id`
---@field entries Rules.Vault.Entry[]|nil   for `family`

---Another spelling of a word that is a ruleset, a rule id or a family: the word in the case it has there.
---@param ctx Rules.Vault.Ctx
---@param index Rules.Vault.Index|nil
---@param word string
---@return string|nil
local function did_you_mean(ctx, index, word)
  local low = word:lower()
  for _, name in ipairs(M.ruleset_names(ctx)) do
    if name:lower() == low then
      return name
    end
  end
  if index then
    local up = word:upper()
    if index.by_id[up] or index.by_family[up] then
      return up
    end
  end
  return nil
end

---Which ruleset, rule id, family and part the typed words mean. A single word that is a part and also the name of a
---ruleset means the ruleset (the part is still there as the second word). A part word alone is the part of the ruleset
---that is settled otherwise (the buffer's, the only one, the chosen one).
---@param ctx Rules.Vault.Ctx
---@param first string|nil
---@param second string|nil
---@return Rules.Vault.Target|nil target
---@return string|nil err
function M.resolve(ctx, first, second)
  if second ~= nil and not M.is_part(second) then
    return nil, ("unknown part '%s' (expected %s)"):format(second, table.concat(M.PARTS, "|"))
  end
  local part = second or M.DEFAULT_PART
  if first == nil then
    return { kind = "none", part = part, part_given = second ~= nil }, nil
  end
  local rs = M.match_ruleset(ctx, first)
  if rs then
    return { kind = "ruleset", name = rs.name, ruleset = rs, part = part, part_given = second ~= nil }, nil
  end
  if M.is_part(first) and second == nil then
    return { kind = "none", part = first, part_given = true }, nil
  end
  local index, err = M.index(ctx)
  if index then
    local entry = index.by_id[first]
    if entry then
      if second then
        return nil, ("a part (%s) goes with a ruleset, not with the rule id %s"):format(second, first)
      end
      return { kind = "id", name = first, part = part, part_given = false, entry = entry }, nil
    end
    local entries = index.by_family[first]
    if entries then
      if second then
        return nil, ("a part (%s) goes with a ruleset, not with the family %s"):format(second, first)
      end
      return { kind = "family", name = first, part = part, part_given = false, entries = entries }, nil
    end
  end
  local names = M.ruleset_names(ctx)
  local text = ("'%s' is neither a ruleset (%s), a rule id nor a family of the vault"):format(
    first,
    #names > 0 and table.concat(names, ", ") or "none yet"
  )
  local hint = did_you_mean(ctx, index, first)
  if hint then
    text = text .. (" -- did you mean %s?"):format(hint)
  elseif not index and err then
    text = text .. " (" .. err .. ")"
  end
  return nil, text
end

-- ── what a target points at ──────────────────────────────────────────────────────────

---@class Rules.Vault.Subject
---@field path string
---@field dir boolean
---@field label string
---@field line integer|nil

---@param path string
---@return boolean
local function is_dir(path)
  local stat = (vim.uv or vim.loop).fs_stat(path)
  return stat ~= nil and stat.type == "directory"
end

---@param path string
---@return boolean
local function is_file(path)
  local stat = (vim.uv or vim.loop).fs_stat(path)
  return stat ~= nil and stat.type == "file"
end

---@param path string
---@return string
local function norm(path)
  return (vim.fs.normalize(path):gsub("(.)/+$", "%1"))
end

---What the user typed after a missing folder, in one phrase.
---@param rs Rules.Vault.Ruleset
---@param part string
---@param path string
---@return string
local function missing(rs, part, path)
  return ("%s has no %s folder yet (%s)"):format(rs.name, part, path)
end

---The files or folder of one part of a ruleset.
---@param rs Rules.Vault.Ruleset
---@param part string
---@return Rules.Vault.Subject[]|nil
---@return string|nil err
function M.part_subjects(rs, part)
  local label = ("%s %s"):format(rs.name, part)
  if part == "all" then
    return { { path = rs.dir, dir = true, label = rs.name } }, nil
  elseif part == "rules" then
    local dir = rs.dir .. "/_rules"
    -- a ruleset of documents with rule blocks has no _rules/: the ruleset folder is where its rules are
    return { { path = is_dir(dir) and dir or rs.dir, dir = true, label = label } }, nil
  elseif part == "layouts" then
    local dir = rs.dir .. "/_layouts"
    if is_dir(dir) then
      return { { path = dir, dir = true, label = label } }, nil
    end
    -- layouts that stand elsewhere in the ruleset: their files
    local out = {}
    for _, layout in ipairs(require("rules.ops").layouts(rs.dir)) do
      out[#out + 1] = { path = norm(layout.path), dir = false, label = label }
    end
    if #out == 0 then
      return nil, missing(rs, part, dir)
    end
    return out, nil
  elseif part == "catalogs" then
    local out, seen = {}, {}
    for _, layout in ipairs(require("rules.ops").layouts(rs.dir)) do
      local path = norm(rs.dir .. "/" .. layout.output)
      if not seen[path] and is_file(path) then
        seen[path] = true
        out[#out + 1] = { path = path, dir = false, label = ("%s %s"):format(rs.name, vim.fs.basename(path)) }
      end
    end
    if #out == 0 then
      return nil, ("%s has no generated document yet: no layout, or :Rules catalog has not run"):format(rs.name)
    end
    table.sort(out, function(a, b)
      return a.path < b.path
    end)
    return out, nil
  end
  return nil, ("unknown part '%s' (expected %s)"):format(part, table.concat(M.PARTS, "|"))
end

---The rulesets that hold rules of a family, in the order of the vault, each with its rules.
---@param ctx Rules.Vault.Ctx
---@param entries Rules.Vault.Entry[]
---@return { ruleset: Rules.Vault.Ruleset, entries: Rules.Vault.Entry[] }[]
local function by_ruleset(ctx, entries)
  local groups = {}
  for _, entry in ipairs(entries) do
    local rs = entry.ruleset
    if rs then
      if not groups[rs.dir] then
        groups[rs.dir] = { ruleset = rs, entries = {} }
      end
      table.insert(groups[rs.dir].entries, entry)
    end
  end
  local out = {}
  for _, rs in ipairs(ctx.rulesets) do
    if groups[rs.dir] then
      out[#out + 1] = groups[rs.dir]
    end
  end
  return out
end

---The folder of a family in each ruleset that has rules of it; where a ruleset keeps its rules in documents (no folder
---of the family) the files of its rules.
---@param ctx Rules.Vault.Ctx
---@param family string
---@param entries Rules.Vault.Entry[]
---@return Rules.Vault.Subject[]
local function family_subjects(ctx, family, entries)
  local out = {}
  for _, group in ipairs(by_ruleset(ctx, entries)) do
    local rs = group.ruleset
    local dir = rs.dir .. "/_rules/" .. family
    local retired_dir = rs.dir .. "/_retired/" .. family
    local active, retired = {}, {}
    for _, entry in ipairs(group.entries) do
      table.insert(entry.retired and retired or active, entry)
    end
    local label = family
    if #active > 0 and is_dir(dir) then
      out[#out + 1] = { path = dir, dir = true, label = label }
    elseif #active == 0 and #retired > 0 and is_dir(retired_dir) then
      out[#out + 1] = { path = retired_dir, dir = true, label = label }
    else
      local seen = {}
      for _, entry in ipairs(group.entries) do
        if not seen[entry.file] then
          seen[entry.file] = true
          out[#out + 1] = { path = norm(entry.file), dir = false, label = label, line = entry.line }
        end
      end
    end
  end
  return out
end

---The files and folders a target means, for a verb that points at them (open, clipboard, link, cdx).
---@param ctx Rules.Vault.Ctx
---@param target Rules.Vault.Target
---@param rs? Rules.Vault.Ruleset  the ruleset settled for a target of kind `none`
---@return Rules.Vault.Subject[]|nil subjects
---@return string|nil err
function M.subjects(ctx, target, rs)
  if target.kind == "id" then
    local entry = target.entry
    if not entry.file or not is_file(entry.file) then
      return nil, ("the file of %s is gone (%s)"):format(entry.id, tostring(entry.file))
    end
    return { { path = norm(entry.file), dir = false, label = entry.id, line = entry.line } }, nil
  elseif target.kind == "family" then
    local out = family_subjects(ctx, target.name, target.entries)
    if #out == 0 then
      return nil, ("the folder of the family %s is not found"):format(target.name)
    end
    return out, nil
  end
  local ruleset = target.ruleset or rs
  if not ruleset then
    return nil, "no ruleset"
  end
  return M.part_subjects(ruleset, target.part)
end

---The folders a search (`find`, `grep`) is rooted at, and the first query. A rule id searches its whole ruleset for the
---id (the files that name it); a family its folder; a ruleset the folder of the part.
---@param ctx Rules.Vault.Ctx
---@param target Rules.Vault.Target
---@param rs? Rules.Vault.Ruleset
---@return string[]|nil roots
---@return string|nil query
---@return string|nil err
function M.search_roots(ctx, target, rs)
  if target.kind == "id" then
    local ruleset = target.entry.ruleset
    if not ruleset then
      return nil, nil, ("%s lies in no ruleset of the vault"):format(target.name)
    end
    return { ruleset.dir }, target.name, nil
  end
  if target.kind == "ruleset" or target.kind == "none" then
    if target.part == "catalogs" then
      return nil, nil, "catalogs are generated documents, not a folder to search: use rules, layouts or all"
    end
  end
  local subjects, err = M.subjects(ctx, target, rs)
  if not subjects then
    return nil, nil, err
  end
  local roots, seen = {}, {}
  for _, subject in ipairs(subjects) do
    -- a family that keeps its rules in documents has files, not a folder: search the folder they are in
    local dir = subject.dir and subject.path or vim.fs.dirname(subject.path)
    if not seen[dir] then
      seen[dir] = true
      roots[#roots + 1] = dir
    end
  end
  return roots, nil, nil
end

-- ── the tree ─────────────────────────────────────────────────────────────────────────

---@param n integer
---@param one string
---@param many string
---@return string
local function count(n, one, many)
  return ("%d %s"):format(n, n == 1 and one or many)
end

---@param entries Rules.Vault.Entry[]
---@return integer active
---@return integer retired
local function tally(entries)
  local active, retired = 0, 0
  for _, entry in ipairs(entries) do
    if entry.retired then
      retired = retired + 1
    else
      active = active + 1
    end
  end
  return active, retired
end

---@param active integer
---@param retired integer
---@return string
local function counts_text(active, retired)
  local text = count(active, "rule", "rules")
  if retired > 0 then
    text = text .. (", %d retired"):format(retired)
  end
  return text
end

---One line for a rule of the tree.
---@param entry Rules.Vault.Entry
---@return string
local function rule_line(entry)
  if entry.retired then
    local by = entry.replaced_by and entry.replaced_by ~= "" and ("  -> " .. entry.replaced_by) or ""
    return ("%s  [retired]%s"):format(entry.id, by)
  end
  return ("%s  [%s]  %s"):format(entry.id, entry.severity or "?", entry.title or "")
end

---The rules of the vault as a tree: ruleset, then family (with its counts), then rule. A retired rule carries the
---marker `[retired]` and the rule that replaced it. Both given: the family inside the ruleset. Neither: every ruleset.
---@param ctx Rules.Vault.Ctx
---@param scope? { ruleset?: Rules.Vault.Ruleset, family?: string }
---@return string[]|nil lines
---@return string|nil err
function M.tree_lines(ctx, scope)
  scope = scope or {}
  local index, err = M.index(ctx)
  if not index then
    return nil, err
  end
  local lines = {}
  for _, rs in ipairs(ctx.rulesets) do
    if not scope.ruleset or scope.ruleset.dir == rs.dir then
      local families, all = {}, {}
      for _, family in ipairs(index.families) do
        if not scope.family or scope.family == family then
          local own = {}
          for _, entry in ipairs(index.by_family[family]) do
            if entry.ruleset and entry.ruleset.dir == rs.dir then
              own[#own + 1] = entry
              all[#all + 1] = entry
            end
          end
          if #own > 0 then
            families[#families + 1] = { family = family, entries = own }
          end
        end
      end
      if #families > 0 or not scope.family then
        local active, retired = tally(all)
        local head = ("%s  %s, %s"):format(rs.name, counts_text(active, retired), count(#families, "family", "families"))
        lines[#lines + 1] = head
        for fi, fam in ipairs(families) do
          local last_family = fi == #families
          local a, r = tally(fam.entries)
          lines[#lines + 1] = ("%s %s  %s"):format(last_family and "└─" or "├─", fam.family, counts_text(a, r))
          local stem = last_family and " " or "│"
          for ri, entry in ipairs(fam.entries) do
            local branch = ri == #fam.entries and "└─" or "├─"
            lines[#lines + 1] = ("%s  %s %s"):format(stem, branch, rule_line(entry))
          end
        end
      end
    end
  end
  local view = ctx.view
  if view and #view.load_errors > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("%s while loading: :Rules check names them (:checkhealth rules shows the vault)"):format(
      count(#view.load_errors, "load error", "load errors")
    )
  end
  return lines, nil
end

-- ── text ─────────────────────────────────────────────────────────────────────────────

---The folder relative paths start at: the one of the current file, else the working directory.
---@param bufnr? integer
---@return string
function M.base_dir(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr or 0)
  if name ~= "" and not name:match("^%a[%w+.-]*://") and vim.bo[bufnr or 0].buftype == "" then
    return vim.fn.fnamemodify(name, ":p:h")
  end
  return vim.fn.getcwd()
end

---A path as a verb writes it: absolute with forward slashes, or with `rel` relative to the folder of the current file.
---(The path is only ever put into a register or a buffer, never into a command: no backslash reaches a command line.)
---@param path string
---@param rel boolean|nil
---@param bufnr? integer
---@return string
function M.display_path(path, rel, bufnr)
  if rel then
    return require("lib.nvim.fs.relpath")(path, M.base_dir(bufnr))
  end
  return norm(path)
end

---A Markdown link: `[<label>](<target>)`; a target with a blank or a parenthesis is wrapped in `<...>`.
---@param label string
---@param target string
---@return string
function M.markdown_link(label, target)
  if target:find("[%s()]") then
    target = "<" .. target .. ">"
  end
  return ("[%s](%s)"):format(label, target)
end

---The prompt `cdx` copies: where to read, and how the rules are changed.
---@param target Rules.Vault.Target
---@param ruleset_name string|nil
---@param paths string[]  as shown
---@return string
function M.cdx_prompt(target, ruleset_name, paths)
  local where = table.concat(paths, ", ")
  local what
  if target.kind == "id" then
    what = ("the rule %s"):format(target.name)
  elseif target.kind == "family" then
    what = ("the rules of the family %s"):format(target.name)
  else
    what = ("the %s of the ruleset %s"):format(target.part, ruleset_name or "?")
  end
  local read = "Read %s (%s) and continue the work on it; summarise what is open before you change anything. "
  local door = "Change rules only through :Rules new, set, retire and move (or the rules-ops/1 door), never by editing the files."
  return (read .. door):format(where, what)
end

return M
