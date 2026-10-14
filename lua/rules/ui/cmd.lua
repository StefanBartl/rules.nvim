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

---The words of the command line after the subcommand, as typed: the words of the argument string (`opts.args`, not
---`fargs`: Neovim halves every backslash pair of `fargs`, drops the backslash before a blank and makes a run of blanks
---one, and a value would not come out as typed). `fargs` is the check that both cut the line the same way; when they
---do not (a handler called with a context that has no argument string) the words of `fargs` are used.
---@param ctx table  composer context
---@return Rules.Word[]
local function typed_words(ctx)
  local raw = ctx.raw or {}
  local fargs = raw.fargs or {}
  if type(raw.args) == "string" then
    local words = cmdline.words(raw.args)
    local same = #words == #fargs
    for i = 1, same and #words or 0 do
      same = same and cmdline.unescape(words[i].text) == fargs[i]
    end
    if same then
      return vim.list_slice(words, #ctx.path + 1, #words)
    end
  end
  local out = {}
  for i = #ctx.path + 1, #fargs do
    out[#out + 1] = { text = fargs[i], sep = " " }
  end
  return out
end

---The words of a command line that are no flag: what the positional argument (the family, the id), the
---`key=value` assignments and the title are read from. The flags are taken apart by the grammar's own split
---(`composer.flags`), exactly as the composer did: a word is a flag when the split of the line up to it says so. A bare
---`--` ends the flags (it is no word itself): `text=run with -- --dry now` has the text `run with --dry now`.
---@param ctx table  composer context
---@param specs table[]  the flags of the route
---@return Rules.Word[]|nil words
---@return string|nil err
function M.words(ctx, specs)
  local split = require("lib.nvim.bindings.usercmd.composer.flags").split
  local route = { flags = specs }
  local words = typed_words(ctx)
  local plain = {}
  for i, word in ipairs(words) do
    plain[i] = cmdline.unescape(word.text)
  end
  local _, _, err = split(route, plain)
  if err then
    return nil, err
  end
  local out, count = {}, 0
  for i = 1, #words do
    local positional = split(route, vim.list_slice(plain, 1, i))
    -- a prefix that ends in a flag that still waits for its value is no answer: the word is no positional
    if positional and #positional > count then
      out[#out + 1] = words[i]
      count = #positional
    end
  end
  return out, nil
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
  if not candidates.family_known(op.family) then
    row("family", op.family .. " (NEW: no rule of any ruleset has it yet)")
  end
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

---Make the rule and open its file.
---@param op table  a `new` operation
---@param dry boolean|nil
local function make(op, dry)
  local result = run({ op }, dry)
  local entry = ok_entry(result)
  if entry and entry.outcome == "created" then
    open_rule(entry.id)
  end
end

---The question before a rule is made in a family that no rule has yet: a family is made by its first rule, and the
---typo of a family (`DPE` for `DEP`) is the way to make one by accident. The door checks first (`dry_run`), so a rule
---it would refuse is told without a question.
---@param op table  a `new` operation
function M.ask_new_family(op)
  local check = write().run({ op }, { dry = true })
  local entry = ok_entry(check)
  if not entry then
    write().say(check, { op })
    return
  end
  if #vim.api.nvim_list_uis() == 0 then
    notify.error(("%s is a new family (no rule has it yet) and there is nobody to ask: run it with --yes"):format(op.family))
    return
  end
  require("rules.ui.confirm").yesno(
    ("New family %s: no rule of any ruleset has it yet.\n\nMake %s as its first rule?"):format(op.family, entry.id or "?"),
    "make it",
    function(yes)
      if yes then
        make(op, false)
      else
        notify.info(("%s was not made"):format(entry.id or "the rule"))
      end
    end
  )
end

---`:Rules new [<FAMILY> [title...]] [severity= text= ruleset=] [--to= --after= --before= --first] [--yes] [--dry]`
---@param ctx table
function M.new(ctx)
  local routes = require("rules.ui.routes")
  local family = ctx.args.family
  local words, werr = M.words(ctx, routes.FLAGS.new)
  if not words then
    notify.error(tostring(werr))
    return
  end
  local bound, serr = cmdline.bind(words, cmdline.NEW_KEYS, false)
  if not bound then
    notify.error(tostring(serr))
    return
  end
  local values = bound.values
  local place, perr = cmdline.place(ctx.flags)
  if not place then
    notify.error(tostring(perr))
    return
  end
  local title = cmdline.join(bound.lead)
  -- the door's own answer, said before anything else: a mistyped title is not a family (`Fix the bug` reads `Fix`)
  local why = family and require("rules.ops").family_error(family)
  if why then
    notify.error(("invalid_argument: family %s"):format(why))
    return
  end
  if family and title ~= "" and values.severity and values.severity ~= "" then
    ---@type table
    local op = vim.tbl_extend("force", { op = "new", family = family, title = title, severity = values.severity }, place)
    if values.text and values.text ~= "" then
      op.text = values.text
    end
    if values.ruleset and values.ruleset ~= "" then
      op.ruleset = values.ruleset
    end
    if ctx.flags.dry or ctx.flags.yes or require("rules.ui.candidates").family_known(family) then
      make(op, ctx.flags.dry)
    else
      M.ask_new_family(op)
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
  local words, werr = M.words(ctx, routes.FLAGS.set)
  if not words then
    notify.error(tostring(werr))
    return
  end
  local bound, serr = cmdline.bind(words, cmdline.SET_KEYS, true)
  if not bound then
    notify.error(tostring(serr))
    return
  end
  local patch, perr = cmdline.patch(bound.values)
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
  local words, werr = M.words(ctx, routes.FLAGS.retire)
  if not words then
    notify.error(tostring(werr))
    return
  end
  local bound, serr = cmdline.bind(words, { "reason" }, true)
  if not bound then
    notify.error(tostring(serr))
    return
  end
  local values = bound.values
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
  local words, werr = M.words(ctx, routes.FLAGS.move)
  if not words then
    notify.error(tostring(werr))
    return
  end
  local bound = cmdline.bind(words, {}, false)
  local left = bound and bound.lead or {}
  if #left > 0 then
    local hint = ""
    if ctx.flags.to then
      hint = " (a blank in a section is written with a backslash before it)"
    end
    notify.error(("unexpected argument: %s%s"):format(cmdline.join(left), hint))
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
