---@module 'rules.ui.cmd'
---@brief The handlers of `:Rules new`, `set`, `retire`, `move` and `list` -- words in, one request to `rules-ops/1` out.
---@description
--- A thin layer: a handler reads the command line (`rules.cmdline`), builds the operation and hands it to the door
--- through `rules.write` (the open buffers are looked after, the answer is told). It checks nothing of a rule itself:
--- a severity that is none, a title that is too long, an id that is not there, a place that does not exist is
--- what the door answers, word for word.
---
---  - `new`: with the family, a title and `severity=` the rule is made; with less, the Markdown form opens with what
---    was given filled in (`rules.ui.form`): checked up front, then `dry_run`, a question that shows what would be
---    made, then the write
---  - `set`: `key=value` words (a value may hold spaces)
---  - `retire`: `dry_run` first, then the question (`--yes` skips it), then the write
---  - `move`: one place (`--to=`, `--after=`, `--before=`)
---  - `list`: the quickfix list, one rule at its source line (`--format=json` prints the document of `rules-export/1`)
---
--- `--dry` on a verb that writes: everything is checked and told, nothing is written.
---
--- Not its job: the grammar and the argument types (`rules.ui.routes`, `rules.bindings.usrcmds`), the rules of a rule
--- (`rules.ops`).

local cmdline = require("rules.cmdline")
local notify = require("rules.util.notify")

local M = {}

---@return table
local function write()
  return require("rules.write")
end

---The words of a command line that are neither a flag nor an argument the grammar bound: what `key=value` assignments
---and the title are read from. The grammar's own split (`composer.flags`) is used, so a flag is taken apart exactly
---as the composer did.
---@param ctx table  composer context
---@param specs table[]  the flags of the route
---@param bound integer  how many positional arguments the grammar bound (the family, the id)
---@return string[]|nil words
---@return string|nil err
function M.words(ctx, specs, bound)
  local fargs = ctx.raw and ctx.raw.fargs or {}
  local tokens = vim.list_slice(fargs, #ctx.path + 1, #fargs)
  local positional, _, err = require("lib.nvim.bindings.usercmd.composer.flags").split({ flags = specs }, tokens)
  if not positional then
    return nil, err
  end
  return vim.list_slice(positional, bound + 1, #positional), nil
end

---Run operations through the door and tell the answer.
---@param op_list table[]
---@param dry boolean|nil
---@return Rules.WriteResult
local function run(op_list, dry)
  local result = write().run(op_list, { dry = dry == true })
  write().say(result, op_list)
  return result
end

---Open the file of a rule.
---@param id string
local function open_rule(id)
  local scan = require("rules.contract").view(nil)
  local path = scan and scan.abs[id]
  if not path then
    return
  end
  -- table form: the path reaches `:edit` as one word, with no escaping to undo
  local ok, err = pcall(vim.cmd, { cmd = "edit", args = { path } })
  if not ok then
    notify.error(("could not open %s: %s"):format(path, tostring(err)))
  end
end

---The first entry of a result when it is ok.
---@param result Rules.WriteResult
---@return table|nil entry
local function ok_entry(result)
  local entry = result.entries[1]
  if result.ok and entry and entry.ok then
    return entry
  end
  return nil
end

---The `Place:` line of the form for what the command line said.
---@param flags table
---@return string
local function place_line(flags)
  if flags.after then
    return "after " .. flags.after
  elseif flags.before then
    return "before " .. flags.before
  end
  return flags.to or ""
end

-- ── new ─────────────────────────────────────────────────────────────────────────

---What the question before a rule is made shows: what will be written, from the request and the dry run.
---@param op table
---@param entry table  the entry of the dry run
---@return string
function M.preview_text(op, entry)
  local candidates = require("rules.ui.candidates")
  local lines = { "Create this rule?", "" }
  local function row(name, value)
    lines[#lines + 1] = ("  %-9s %s"):format(name, value)
  end
  row("id", (entry.id or "?") .. " (given when it is written)")
  row("severity", op.severity)
  row("title", vim.fn.strcharpart(op.title, 0, 60) .. (vim.fn.strchars(op.title) > 60 and "..." or ""))
  if op.text then
    row("text", ("%d line(s)"):format(#vim.split(op.text, "\n", { plain = true })))
  end
  local ruleset = op.ruleset or candidates.ruleset_names()[1]
  row("file", ("%s/_rules/%s/%s.md"):format(ruleset or "<ruleset>", op.family, entry.id or "?"))
  if entry.placed and entry.placed.layout then
    row("place", entry.placed.layout)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Back returns to the form: nothing is created."
  return table.concat(lines, "\n")
end

---The form of `:Rules new`: checked up front, `dry_run`, a question that shows what would be made, then the write.
---A refusal of the engine is shown in the form, which stays open with everything typed; cancelling makes nothing.
---@param given Rules.FormOpts  what the command line already said
function M.new_form(given)
  local candidates = require("rules.ui.candidates")
  local ui = require("rules.ui.form")
  local confirm = require("rules.ui.confirm")
  local opts = vim.tbl_extend("force", {
    families = candidates.families(),
    layouts = candidates.layout_outputs(),
    rulesets = candidates.ruleset_names(),
  }, given)
  opts.on_cancel = function()
    notify.info("rule not created")
  end
  opts.on_submit = function(op, buf)
    ---@param text string
    local function back_to_form(text)
      if vim.api.nvim_buf_is_valid(buf) then
        ui.show_errors(buf, { text })
      else
        notify.error(text)
      end
    end
    local dry = write().run({ op }, { dry = true })
    local entry = dry.entries[1]
    if dry.err or not (dry.ok and entry and entry.ok) then
      local err = dry.err or (entry and entry.error) or {}
      back_to_form(("%s: %s"):format(err.code or "error", err.message or "the engine refused the request"))
      return
    end
    confirm.choose(M.preview_text(op, entry), { "Back to the form", "Create the rule" }, function(index)
      -- Esc, `q`, a dialog that could not open: not an answer. Nothing is written and the form stays open.
      if index ~= 2 then
        notify.info("rule not created: the form is still open")
        return
      end
      local result = write().run({ op })
      local made = ok_entry(result)
      if not made then
        local err = result.err or (result.entries[1] and result.entries[1].error) or {}
        back_to_form(("%s: %s"):format(err.code or "error", err.message or "the rule could not be created"))
        return
      end
      ui.close(buf)
      write().say(result, { op })
      open_rule(made.id)
    end)
  end
  local open = M.form_open or ui.open
  open(opts)
end

---The seam the specs use in place of the form buffer: same signature as `rules.ui.form.open`.
---@type (fun(opts: Rules.FormOpenOpts): any)|nil
M.form_open = nil

---`:Rules new [<FAMILY> [title...]] [severity= text= ruleset=] [--to= --after= --before= --first] [--dry]`
---@param ctx table
function M.new(ctx)
  local routes = require("rules.ui.routes")
  local family = ctx.args.family
  local words, werr = M.words(ctx, routes.FLAGS.new, family and 1 or 0)
  if not words then
    notify.error(tostring(werr))
    return
  end
  local lead, values, serr = cmdline.split_assignments(words, cmdline.NEW_KEYS, false)
  if not lead or not values then
    notify.error(tostring(serr))
    return
  end
  local place, perr = cmdline.place(ctx.flags)
  if not place then
    notify.error(tostring(perr))
    return
  end
  local title = table.concat(lead, " ")
  if family and title ~= "" and values.severity and values.severity ~= "" then
    ---@type table
    local op = vim.tbl_extend("force", { op = "new", family = family, title = title, severity = values.severity }, place)
    if values.text and values.text ~= "" then
      op.text = values.text
    end
    if values.ruleset and values.ruleset ~= "" then
      op.ruleset = values.ruleset
    end
    local result = run({ op }, ctx.flags.dry)
    local entry = ok_entry(result)
    if entry and entry.outcome == "created" then
      open_rule(entry.id)
    end
    return
  end
  if ctx.flags.dry then
    notify.error(":Rules new --dry needs the family, a title and severity= (without them it opens the form)")
    return
  end
  if ctx.flags.first then
    notify.warn("--first is not part of the form: the rule goes to the end of the section")
  end
  M.new_form({
    family = family,
    title = title ~= "" and title or nil,
    severity = values.severity,
    text = values.text,
    ruleset = values.ruleset,
    place = place_line(ctx.flags),
  })
end

-- ── set ─────────────────────────────────────────────────────────────────────────

---`:Rules set <ID> key=value ... [--dry]`
---@param ctx table
function M.set(ctx)
  local routes = require("rules.ui.routes")
  local words, werr = M.words(ctx, routes.FLAGS.set, 1)
  if not words then
    notify.error(tostring(werr))
    return
  end
  local _, values, serr = cmdline.split_assignments(words, cmdline.SET_KEYS, true)
  if not values then
    notify.error(tostring(serr))
    return
  end
  local patch, perr = cmdline.patch(values)
  if not patch then
    notify.error(tostring(perr))
    return
  end
  run({ { op = "set", id = ctx.args.id, patch = patch } }, ctx.flags.dry)
end

-- ── retire ──────────────────────────────────────────────────────────────────────

---`:Rules retire <ID> [--by=<ID>] [reason=...] [--yes] [--dry]`
---@param ctx table
function M.retire(ctx)
  local routes = require("rules.ui.routes")
  local words, werr = M.words(ctx, routes.FLAGS.retire, 1)
  if not words then
    notify.error(tostring(werr))
    return
  end
  local _, values, serr = cmdline.split_assignments(words, { "reason" }, true)
  if not values then
    notify.error(tostring(serr))
    return
  end
  local id = ctx.args.id
  ---@type table
  local op = { op = "retire", id = id, replaced_by = ctx.flags.by }
  if values.reason and values.reason ~= "" then
    op.reason = values.reason
  end

  -- the door checks first (an id that is not there, a rule it cannot retire): the question is asked only for a
  -- step that would happen
  local dry = write().run({ op }, { dry = true })
  if ctx.flags.dry or not ok_entry(dry) then
    write().say(dry, { op })
    return
  end
  local function go()
    run({ op }, false)
  end
  if ctx.flags.yes then
    go()
    return
  end
  if #vim.api.nvim_list_uis() == 0 then
    notify.error(("retire asks before it moves %s, and there is nobody to ask: run it with --yes"):format(id))
    return
  end
  local by = op.replaced_by and (" Replaced by %s."):format(op.replaced_by) or ""
  require("rules.ui.confirm").yesno(
    ("Retire %s?\n\nIts file moves to _retired/, the id stays taken, and it leaves every layout.%s"):format(id, by),
    "retire",
    function(yes)
      if yes then
        go()
      else
        notify.info(("%s was not retired"):format(id))
      end
    end
  )
end

-- ── move ────────────────────────────────────────────────────────────────────────

---`:Rules move <ID> (--to=<file>#<section> | --after=<ID> | --before=<ID>) [--first] [--dry]`
---@param ctx table
function M.move(ctx)
  local routes = require("rules.ui.routes")
  local words, werr = M.words(ctx, routes.FLAGS.move, 1)
  if not words then
    notify.error(tostring(werr))
    return
  end
  if #words > 0 then
    local hint = ""
    if ctx.flags.to then
      hint = " (a blank in a section is written with a backslash before it)"
    end
    notify.error(("unexpected argument: %s%s"):format(table.concat(words, " "), hint))
    return
  end
  local place, perr = cmdline.place(ctx.flags)
  if not place then
    notify.error(tostring(perr))
    return
  end
  if next(place) == nil then
    notify.error(":Rules move needs a place: --to=<file>#<section>, --after=<ID> or --before=<ID>")
    return
  end
  run({ vim.tbl_extend("force", { op = "move", id = ctx.args.id }, place) }, ctx.flags.dry)
end

-- ── list ────────────────────────────────────────────────────────────────────────

---`:Rules list [--family=<PREFIX>] [--severity=<level>] [--format=json]`
---@param ctx table
function M.list(ctx)
  local params = { family = ctx.flags.family, severity = ctx.flags.severity }
  if ctx.flags.format == "json" then
    local text = require("rules.api").call("list", { params = vim.tbl_extend("force", params, { limit = 500 }) })
    print(text)
    return
  end
  local contract = require("rules.contract")
  local found, offset = {}, 0
  local total
  repeat
    local doc, err = contract.list(vim.tbl_extend("force", params, { limit = contract.MAX_LIST_ITEMS, offset = offset }))
    if not doc then
      notify.error(("%s: %s"):format(err and err.code or "error", err and err.message or "the rules could not be listed"))
      return
    end
    total = doc.total
    for _, item in ipairs(doc.items) do
      found[#found + 1] = item
    end
    offset = offset + #doc.items
    if #doc.items == 0 then
      break
    end
  until offset >= total
  if #found == 0 then
    notify.info("no rule matches")
    return
  end
  local scan = contract.view(nil)
  local items = {}
  for _, item in ipairs(found) do
    local file = scan and scan.abs[item.id]
    if file then
      -- the engine's title is the heading text, "`DEP-06` — the title": the id is shown in front already
      local title = (item.title:gsub("^`" .. vim.pesc(item.id) .. "`%s*—%s*", ""))
      items[#items + 1] = { id = item.id, severity = item.severity, title = title, file = file, line = item.line }
    end
  end
  require("rules.report.quickfix").set_rules(items, "rules list")
  vim.cmd("copen")
  notify.info(("%d rule(s) in the quickfix list"):format(#items))
end

return M
