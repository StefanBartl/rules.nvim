---@module 'rules.ui.vault_cmd'
---@brief The handlers behind `:RulesVault` -- open, copy, link, search and show the rules of the vault, and make a vault.
---@description
--- `:RulesVault <verb> [<ruleset>|<ID>|<FAMILY>] [<part>]`. The verb says what happens; the word says where (a ruleset of
--- the vault, a rule id, a family: the ruleset of the current buffer, the only one, or a pick when left out); the part
--- (`rules` default, `layouts`, `catalogs`, `all`) narrows a ruleset.
---
---   open       the rule file of an id, the folder of a family, or a part of a ruleset (a folder in the explorer,
---              a generated document in a buffer)
---   clipboard  the path to the + register (--rel: relative to the current file; --link: `[DEP-06](path)`)
---   link       a Markdown link at the cursor, relative to the current file
---   find|grep  a pickers.nvim picker rooted at the ruleset (an id: its ruleset, searching for the id), the family or
---              the part
---   tree       the ruleset as a tree: family, then rules, `[retired]` marked, counts per family
---   cdx        a prompt for an agent session to the + register (the same thin path as `:TasksVault cdx`: there is
---              no generic way here to start a session, so the prompt is copied)
---   create     a vault: lists first what happens and what is left to you, then asks (--yes skips the question)
---
--- With no vault every verb but `create` says so once and does nothing else (a stray word on the command line
--- included: the missing vault is what is reported). A vault that is named but not there is an error that says where it
--- was named. There is no `new` and no `paste`: `:Rules new` makes a rule, and this command writes nothing but the
--- scaffold of `create`.
---
--- Not its job: the paths (`rules.vault_ops`), the scaffold (`rules.vault_scaffold`), the grammar (`rules.ui.vault_routes`).

local notify = require("rules.util.notify")
local ops = require("rules.vault_ops")

local M = {}

---Seam for the clipboard (`nil`: lib.nvim's `cross.copy_to_clipboard`); specs replace it.
---@type (fun(text: string): boolean)|nil
M.copy = nil

---Seam for a pick from a list (`nil`: `vim.ui.select`); specs replace it.
---@type (fun(items: string[], opts: table, cb: fun(choice: string|nil, index: integer|nil)))|nil
M.select = nil

---Seam for the explorer (`nil`: `:Filetree open` when there is one, else the editor's own); specs replace it.
---@type (fun(dir: string))|nil
M.explorer_open = nil

---Seam for the picker backend: `command, engine` of pickers.nvim, or nothing (`nil`: asks pickers.nvim).
---@type (fun(): table|nil, table|nil)|nil
M.pickers_backend = nil

---Seam for the window the tree is shown in (`nil`: the report window `rules.report.window`).
---@type (fun(lines: string[]))|nil
M.show = nil

---@param text string
---@return boolean
local function copy(text)
  if M.copy then
    return M.copy(text)
  end
  return require("lib.nvim.cross.copy_to_clipboard")(text) and true or false
end

---Whether there is a screen to ask on.
---@return boolean
local function has_ui()
  return #vim.api.nvim_list_uis() > 0
end

---The vault and its rulesets, or the one message of why there is none.
---@return Rules.Vault.Ctx|nil
local function vault_ctx()
  local ctx, kind, message = ops.context()
  if ctx then
    return ctx
  end
  if kind == "none" then
    notify.warn(("%s -- :RulesVault create <dir> makes one"):format(tostring(message)))
  else
    -- named, but not there or not usable: the message says where it was named
    notify.error(tostring(message))
  end
  return nil
end

---Report words after the arguments a verb does not take (the command line splits at spaces).
---@param ctx table
---@return boolean ok
local function no_stray_words(ctx)
  if ctx.rest and #ctx.rest > 0 then
    notify.error("unexpected argument: " .. table.concat(ctx.rest, " "))
    return false
  end
  return true
end

---Settle the vault and the words of a verb that takes no free text: the vault first, so a missing vault is the one
---thing reported.
---@param ctx table
---@return Rules.Vault.Ctx|nil
local function prepare(ctx)
  local vctx = vault_ctx()
  if not vctx then
    return nil
  end
  if not no_stray_words(ctx) then
    return nil
  end
  return vctx
end

---A pick from a list: the seam, or `vim.ui.select`; without a screen to ask on, the choice is told as an error.
---@param items string[]
---@param prompt string
---@param cb fun(index: integer)
local function choose(items, prompt, cb)
  if not M.select and not has_ui() then
    notify.error(("%s: there is nobody to ask. Name one: %s"):format(prompt:gsub("[>%s]+$", ""), table.concat(items, ", ")))
    return
  end
  local select = M.select or vim.ui.select
  select(items, { prompt = prompt }, function(choice, index)
    if choice == nil then
      return
    end
    cb(index or vim.fn.index(items, choice) + 1)
  end)
end

---Settle which ruleset a word-less target means: the one of the current buffer, the only one, else a pick.
---@param vctx Rules.Vault.Ctx
---@param cb fun(rs: Rules.Vault.Ruleset)
local function settle_ruleset(vctx, cb)
  local rs = ops.ruleset_of_buffer(vctx)
  if rs then
    return cb(rs)
  end
  if #vctx.rulesets == 0 then
    notify.warn("The vault has no ruleset yet: :RulesVault create <dir> <name> makes one")
    return
  end
  if #vctx.rulesets == 1 then
    return cb(vctx.rulesets[1])
  end
  choose(ops.ruleset_names(vctx), "Ruleset> ", function(index)
    cb(vctx.rulesets[index])
  end)
end

---Resolve the vault, the words and the ruleset, then hand over.
---@param ctx table
---@param cb fun(vctx: Rules.Vault.Ctx, target: Rules.Vault.Target, rs: Rules.Vault.Ruleset|nil)
local function with_target(ctx, cb)
  local vctx = prepare(ctx)
  if not vctx then
    return
  end
  local target, err = ops.resolve(vctx, ctx.args.target, ctx.args.part)
  if not target then
    notify.error(tostring(err))
    return
  end
  if target.kind ~= "none" then
    return cb(vctx, target, nil)
  end
  settle_ruleset(vctx, function(rs)
    cb(vctx, target, rs)
  end)
end

---The files and folders the target points at, or a warning why there are none.
---@param vctx Rules.Vault.Ctx
---@param target Rules.Vault.Target
---@param rs Rules.Vault.Ruleset|nil
---@return Rules.Vault.Subject[]|nil
local function subjects(vctx, target, rs)
  local list, err = ops.subjects(vctx, target, rs)
  if not list then
    notify.warn(tostring(err))
    return nil
  end
  return list
end

-- ── the places a path goes to ────────────────────────────────────────────────────────

---@param path string
---@param line? integer
local function open_file(path, line)
  -- table form: the path reaches `:edit` as one word, with no escaping to undo
  local ok, err = pcall(vim.cmd, { cmd = "edit", args = { path } })
  if not ok then
    notify.error(("cannot open %s: %s"):format(path, tostring(err)))
    return
  end
  if line and line > 1 then
    pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
  end
end

---@param dir string
local function open_explorer(dir)
  if M.explorer_open then
    M.explorer_open(dir)
    return
  end
  if vim.fn.exists(":Filetree") == 2 then
    -- table form: the argument reaches the command as one word, no `fnameescape` backslashes to undo
    local ok = pcall(vim.cmd, { cmd = "Filetree", args = { "open", dir } })
    if ok then
      return
    end
  end
  local ok, err = pcall(vim.cmd, { cmd = "edit", args = { dir } })
  if not ok then
    notify.error(("cannot open %s: %s"):format(dir, tostring(err)))
  end
end

---The paths of subjects as a verb writes them.
---@param list Rules.Vault.Subject[]
---@param rel boolean|nil
---@return string[]
local function shown(list, rel)
  local out = {}
  for _, subject in ipairs(list) do
    out[#out + 1] = ops.display_path(subject.path, rel)
  end
  return out
end

---Put the lines into the current buffer at the cursor. A buffer that cannot take them gets the clipboard instead.
---@param lines string[]
---@param what string
local function insert_at_cursor(lines, what)
  local buf = vim.api.nvim_get_current_buf()
  local placed = vim.bo[buf].buftype ~= "terminal"
    and require("lib.nvim.markdown.link_cursor").insert_links(buf, vim.api.nvim_get_current_win(), lines, { startinsert = false })
  if placed then
    return
  end
  if copy(table.concat(lines, "\n")) then
    notify.warn(("This buffer cannot take text; %s is in the + register instead"):format(what))
  else
    notify.error("This buffer cannot take text and the clipboard is not available")
  end
end

-- ── verbs ────────────────────────────────────────────────────────────────────────────

---`:RulesVault open [<ruleset>|<ID>|<FAMILY>] [<part>]`
---@param ctx table
function M.open(ctx)
  with_target(ctx, function(vctx, target, rs)
    local list = subjects(vctx, target, rs)
    if not list then
      return
    end
    local function go(subject)
      if subject.dir then
        open_explorer(subject.path)
      else
        open_file(subject.path, subject.line)
      end
    end
    if #list == 1 then
      return go(list[1])
    end
    choose(shown(list), "Open> ", function(index)
      go(list[index])
    end)
  end)
end

---The label of a subject in a Markdown link: the id, the family, or the ruleset and part.
---@param subject Rules.Vault.Subject
---@return string
local function link_label(subject)
  return subject.label
end

---`:RulesVault clipboard [<ruleset>|<ID>|<FAMILY>] [<part>] [--rel] [--link]`
---@param ctx table
function M.clipboard(ctx)
  with_target(ctx, function(vctx, target, rs)
    local list = subjects(vctx, target, rs)
    if not list then
      return
    end
    local paths = shown(list, ctx.flags and ctx.flags.rel)
    local lines = {}
    for i, path in ipairs(paths) do
      lines[i] = (ctx.flags and ctx.flags.link) and ops.markdown_link(link_label(list[i]), path) or path
    end
    local text = table.concat(lines, "\n")
    if copy(text) then
      notify.info("Copied " .. text)
    else
      notify.error("Could not write to the clipboard")
    end
  end)
end

---`:RulesVault link [<ruleset>|<ID>|<FAMILY>] [<part>]` -- `[DEP-06](../rulesets/lua/_rules/DEP/DEP-06.md)`.
---@param ctx table
function M.link(ctx)
  with_target(ctx, function(vctx, target, rs)
    local list = subjects(vctx, target, rs)
    if not list then
      return
    end
    local links = {}
    for i, path in ipairs(shown(list, true)) do
      links[i] = ops.markdown_link(link_label(list[i]), path)
    end
    insert_at_cursor(links, "the link")
  end)
end

---The command and engine of pickers.nvim, when it is there.
---@return table|nil command
---@return table|nil engine
local function pickers_backend()
  if M.pickers_backend then
    return M.pickers_backend()
  end
  local safe = require("lib.nvim.require").safe
  local ok, command = safe("pickers.command")
  if not (ok and type(command) == "table" and command.dispatch) then
    return nil, nil
  end
  local found, engines = safe("pickers.engines")
  if not (found and type(engines) == "table" and engines.load) then
    return nil, nil
  end
  local engine = engines.load()
  if not engine then
    return nil, nil
  end
  return command, engine
end

---The shared body of `find` and `grep`.
---@param ctx table
---@param action "files"|"grep"
local function pick(ctx, action)
  with_target(ctx, function(vctx, target, rs)
    local roots, query, err = ops.search_roots(vctx, target, rs)
    if not roots then
      notify.warn(tostring(err))
      return
    end
    local command, engine = pickers_backend()
    if not command then
      notify.warn("pickers.nvim is not available: opening the folder in the explorer instead")
      open_explorer(roots[1])
      return
    end
    local name = target.name or (target.ruleset and target.ruleset.name) or (rs and rs.name) or "rules"
    command.dispatch(action, { roots = roots, prompt = ("%s> "):format(name), query = query }, engine)
  end)
end

---`:RulesVault find [<ruleset>|<ID>|<FAMILY>] [<part>]`
---@param ctx table
function M.find(ctx)
  pick(ctx, "files")
end

---`:RulesVault grep [<ruleset>|<ID>|<FAMILY>] [<part>]`
---@param ctx table
function M.grep(ctx)
  pick(ctx, "grep")
end

---`:RulesVault tree [<ruleset>|<ID>|<FAMILY>]`
---@param ctx table
function M.tree(ctx)
  with_target(ctx, function(vctx, target, rs)
    if target.part_given then
      notify.error(("tree shows the rules of a ruleset family by family: it takes no part (%s)"):format(target.part))
      return
    end
    ---@type { ruleset?: Rules.Vault.Ruleset, family?: string }
    local scope
    if target.kind == "family" then
      scope = { family = target.name }
    elseif target.kind == "id" then
      scope = { family = target.entry.family }
    else
      scope = { ruleset = target.ruleset or rs }
    end
    local lines, err = ops.tree_lines(vctx, scope)
    if not lines then
      notify.warn(tostring(err))
      return
    end
    if #lines == 0 then
      notify.info("no rules to show")
      return
    end
    (M.show or require("rules.report.window").open)(lines)
  end)
end

---`:RulesVault cdx [<ruleset>|<ID>|<FAMILY>] [<part>] [--rel]`
---@param ctx table
function M.cdx(ctx)
  with_target(ctx, function(vctx, target, rs)
    local list = subjects(vctx, target, rs)
    if not list then
      return
    end
    local ruleset = target.ruleset or rs
    local text = ops.cdx_prompt(target, ruleset and ruleset.name, shown(list, ctx.flags and ctx.flags.rel))
    if copy(text) then
      notify.info(
        ("Copied a prompt for %s"):format(target.name or (ruleset and (ruleset.name .. " " .. target.part)) or "the vault")
      )
    else
      notify.error("Could not write to the clipboard")
    end
  end)
end

-- ── create ───────────────────────────────────────────────────────────────────────────

---A folder word as typed: the line is read from the argument string, so a UNC path (`\\server\share`) keeps both
---backslashes; only a backslash before a blank (how a folder with a blank is typed) is undone.
---@param word string
---@return string
local function typed_path(word)
  return (word:gsub("\\ ", " "))
end

---`:RulesVault create [<dir>] [<name>] [--git] [--yes] [--force]`
---
---Says first what will happen and what is left to the user (confirmation; `--yes` skips it), makes the folder and the
---files that are missing, and never overwrites one. What lets rules.nvim find the vault afterwards is the `vault` option
---of `setup()` (or `$RULES_VAULT`): the plan names that step before and the result names it again.
---@param ctx table
function M.create(ctx)
  local routes = require("rules.ui.vault_routes")
  local words, werr = require("rules.ui.cmd").words(ctx, routes.FLAGS.create)
  if not words then
    notify.error(tostring(werr))
    return
  end
  if #words > 2 then
    local extra = {}
    for i = 3, #words do
      extra[#extra + 1] = words[i].text
    end
    notify.error("unexpected argument: " .. table.concat(extra, " "))
    return
  end
  local flags = ctx.flags or {}
  local dir = words[1] and typed_path(words[1].text) or (ctx.args and ctx.args.dir)
  local name = words[2] and words[2].text or (ctx.args and ctx.args.name)

  local scaffold = require("rules.vault_scaffold")

  local function make(target)
    -- planned again, now: the question may have been open for a while
    local plan, perr = scaffold.plan(target, { git = flags.git })
    if not plan then
      notify.error(tostring(perr))
      return
    end
    local res, err = scaffold.create(plan)
    if not res then
      notify.error(tostring(err))
      return
    end
    local copied = copy(scaffold.setup_line(res.root))
    notify.warn(scaffold.created_message(res, copied))
  end

  local function plan_and_make(chosen)
    -- checked before the question, so a folder or a name that is refused is not first offered
    local target, terr = scaffold.check_target(chosen, name)
    if not target then
      notify.error(tostring(terr))
      return
    end
    local current = require("rules.vault").root()
    if current and not flags.force and not ops.same_path(current, target.root) then
      notify.warn(("A vault is in use already (%s). :RulesVault create --force <dir> makes another one"):format(current))
      return
    end
    local plan, perr = scaffold.plan(target, { git = flags.git })
    if not plan then
      notify.error(tostring(perr))
      return
    end
    if flags.yes then
      return make(target)
    end
    if not has_ui() then
      notify.error("create asks before it writes, and there is nobody to ask: run it with --yes")
      return
    end
    require("rules.ui.confirm").yesno(scaffold.plan_text(plan), "create it", function(accepted)
      if accepted then
        make(target)
      else
        notify.info("the vault was not created")
      end
    end)
  end

  if dir and dir ~= "" then
    return plan_and_make(dir)
  end
  if not has_ui() then
    notify.error("create needs a folder when there is nobody to ask: :RulesVault create <dir> --yes")
    return
  end
  vim.ui.input({
    prompt = "Vault folder (name and location): ",
    default = vim.fs.joinpath(vim.fn.expand("~"), "rules-vault"),
    completion = "dir",
  }, function(input)
    if input and vim.trim(input) ~= "" then
      plan_and_make(vim.trim(input))
    end
  end)
end

-- ── bare command ─────────────────────────────────────────────────────────────────────

---`:RulesVault`: the vault in use.
---@param ctx table
function M.status(ctx)
  local vctx = prepare(ctx)
  if not vctx then
    return
  end
  local where = require("rules.settings").VAULT_WHERE[vctx.source or ""] or "?"
  local lines = { ("Vault: %s (from %s)"):format(vctx.root, where) }
  local names = ops.ruleset_names(vctx)
  lines[#lines + 1] = #names > 0 and ("rulesets: " .. table.concat(names, ", ")) or "no ruleset yet"
  local state = require("rules.vault").git_state(vctx.root)
  if state then
    if not state.repo then
      lines[#lines + 1] = "git: not a repository of its own"
    elseif state.clean then
      lines[#lines + 1] = "git: clean"
    else
      lines[#lines + 1] = ("git: %d uncommitted path(s)"):format(state.changes)
    end
  end
  lines[#lines + 1] = ":RulesVault open|clipboard|link|find|grep|tree|cdx [<ruleset>|<ID>|<FAMILY>] [rules|layouts|catalogs|all]"
  notify.info(table.concat(lines, "\n"))
end

return M
