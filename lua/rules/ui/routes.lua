---@module 'rules.ui.routes'
---@brief The grammar of the write verbs of `:Rules` for `lib.nvim`'s composer -- one tree: dispatch, `<Tab>`, option float.
---@description
--- `new`, `set`, `retire`, `move` and `list`, each with the flags and `key=` pairs it takes. Every flag, every `key=`
--- and every positional argument carries a `desc`: the option float (the help of the command line) shows it, and
--- `TESTS/usrcmds_help_spec.lua` pins that none is left without. The handlers are in `rules.ui.cmd`; this file only
--- says what a command line may look like.
---
---  - `:Rules new [<FAMILY> [title...]] [severity= text= ruleset=] [--to= --after= --before= --first] [--dry]`
---  - `:Rules set <ID> key=value ... [--dry]`
---  - `:Rules retire <ID> [--by=<ID>] [reason=...] [--yes] [--dry]`
---  - `:Rules move <ID> (--to=<file>#<section> | --after=<ID> | --before=<ID>) [--first] [--dry]`
---  - `:Rules list [--family=<PREFIX>] [--severity=<level>] [--format=json]`
---
--- Not its job: running anything (`rules.ui.cmd`), the argument types (`rules.bindings.usrcmds`).

local M = {}

---@return string[]
local function severities()
  return require("rules.form").severities()
end

---@param name string
---@return fun(ctx: table)
local function handler(name)
  return function(ctx)
    require("rules.ui.cmd")[name](ctx)
  end
end

local DRY = { name = "dry", bool = true, desc = "Check everything and say what would happen, write nothing" }

---The place of a rule in a layout: where `new` puts it and where `move` takes it.
---@type table[]
local PLACE = {
  { name = "to", type = "RULES_PLACE", desc = "Layout and section: <file>#<section>, or just <file> for its top" },
  { name = "after", type = "RULES_ID", desc = "Put it right after this rule, in the layout that holds that rule" },
  { name = "before", type = "RULES_ID", desc = "Put it right before this rule, in the layout that holds that rule" },
  { name = "first", bool = true, desc = "With --to=<file>#<section>: the start of the section, not its end" },
}

---@param ... table[]
---@return table[]
local function concat(...)
  local out = {}
  for _, list in ipairs({ ... }) do
    vim.list_extend(out, list)
  end
  return out
end

---The flags of each route, also read by the handlers (`rules.ui.cmd.words` takes a command line apart the way the
---composer does).
---@type table<string, table[]>
M.FLAGS = {
  new = concat(PLACE, { DRY }),
  set = { DRY },
  retire = {
    { name = "by", type = "RULES_ID", desc = "The rule that takes its place (recorded as replaced_by)" },
    { name = "yes", bool = true, desc = "Retire without asking" },
    DRY,
  },
  move = concat(PLACE, { DRY }),
}

local SEVERITY_DESC = "How serious a failure of the rule is"

---The routes, to be put into the `:Rules` verb.
---@return table[]
function M.routes()
  return {
    {
      path = { "new" },
      args = {
        {
          name = "family",
          type = "RULES_FAMILY",
          optional = true,
          desc = "Family of the new rule, letters such as DEP (none: open the form)",
        },
      },
      kv = {
        { key = "severity", type = "STRING", values = severities(), desc = SEVERITY_DESC },
        { key = "text", type = "STRING", desc = "Prose of the rule (a value may hold spaces)" },
        { key = "ruleset", type = "RULES_RULESET", desc = "Ruleset to make it in (default: the first)" },
      },
      flags = M.FLAGS.new,
      desc = "Make a rule in the next free id of the family. The words after the family are the title; "
        .. "with a title and severity= the rule is made and opened, with less the Markdown form opens "
        .. "(family, title, severity, place, text; <C-s> checks it, shows what would be made and asks)",
      run = handler("new"),
    },
    {
      path = { "set" },
      args = { { name = "id", type = "RULES_ID", desc = "Id of the rule to change, e.g. DEP-06" } },
      kv = {
        { key = "severity", type = "STRING", values = severities(), desc = SEVERITY_DESC },
        { key = "title", type = "STRING", desc = "New title, one line (a value may hold spaces)" },
        { key = "text", type = "STRING", desc = "New prose of the rule (a value may hold spaces)" },
        { key = "check", type = "STRING", desc = "The check as a JSON object, or nothing to remove it" },
        { key = "agent", type = "STRING", desc = "The agent question as a JSON object, or nothing to remove it" },
      },
      flags = M.FLAGS.set,
      desc = "Change parts of a rule's file (key=value, a value may hold spaces): everything else in the file stays "
        .. "byte for byte; an open buffer of the file is reloaded, one with unsaved changes is reported",
      run = handler("set"),
    },
    {
      path = { "retire" },
      args = { { name = "id", type = "RULES_ID", desc = "Id of the rule to retire, e.g. DEP-06" } },
      kv = { { key = "reason", type = "STRING", desc = "Why it is retired (a value may hold spaces)" } },
      flags = M.FLAGS.retire,
      desc = "Move a rule's file to _retired/ and out of every layout; its id stays taken. Asks first (--yes skips "
        .. "the question), --by=<ID> names the rule that takes its place",
      run = handler("retire"),
    },
    {
      path = { "move" },
      args = { { name = "id", type = "RULES_ID", desc = "Id of the rule to move, e.g. DEP-06" } },
      flags = M.FLAGS.move,
      desc = "Move a rule's {{rule ID}} line within its layout or into another (--to=<file>#<section>, or "
        .. "--after=<ID> / --before=<ID>); the rule's own file is not touched",
      run = handler("move"),
    },
    {
      path = { "list" },
      flags = {
        { name = "family", type = "RULES_FAMILY", desc = "Only the rules of this family, e.g. DEP" },
        { name = "severity", type = "STRING", values = severities(), desc = "Only the rules of this severity" },
        {
          name = "format",
          type = "STRING",
          values = { "json" },
          desc = "Print the rules as JSON (the rules.list document) instead of the quickfix list",
        },
      },
      desc = "List the rules in the quickfix list, each at its source line; --family= and --severity= narrow it, "
        .. "--format=json prints the document of the machine contract",
      run = handler("list"),
    },
  }
end

return M
