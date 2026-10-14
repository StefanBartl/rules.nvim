---@module 'rules.ui.vault_routes'
---@brief The grammar of `:RulesVault` for `lib.nvim`'s composer -- one tree: dispatch, `<Tab>`, option float.
---@description
--- ```
--- :RulesVault open|clipboard|link|find|grep|tree|cdx [<ruleset>|<ID>|<FAMILY>] [<part>]
--- :RulesVault create [<dir>] [<name>] [--git] [--yes] [--force]
--- ```
--- `<part>` is `rules` (default), `layouts`, `catalogs` or `all`. A rule id or a family has no part. Every flag and every
--- positional argument carries a `desc`: the option float shows it, and `TESTS/vault_cmd_spec.lua` pins that none is left
--- without. The handlers are in `rules.ui.vault_cmd`; this file only says what a command line may look like.
---
--- Argument type registered here (`rules.bindings.usrcmds` calls `register_types`, after `RULES_ID` and `RULES_FAMILY`):
---  - `RULES_VAULT_TARGET`: a ruleset of the vault, a rule id, a family, or a part word. The ids and the families are
---    the ones `RULES_ID` and `RULES_FAMILY` offer; the rulesets are read from the vault on every <Tab> and fail soft
---    (no vault: no candidates). It accepts any word: the handler says what a word is, or that it is nothing.
---
--- `create` is not a verb that points at something: it makes the vault. Neither `new` nor `paste` exist here
--- (`:Rules new` makes a rule; a rule is never written by this command).
---
--- Not its job: running anything (`rules.ui.vault_cmd`), the paths (`rules.vault_ops`).

local M = {}

---@return table
local function cmd()
  return require("rules.ui.vault_cmd")
end

---@param candidates string[]
---@param lead string
---@return string[]
local function prefix(candidates, lead)
  local fold = require("rules.vault_ops").fold
  local out = {}
  for _, candidate in ipairs(candidates) do
    -- `fold` changes nothing where the file system tells `lua` and `Lua` apart
    if fold(candidate:sub(1, #lead)) == fold(lead) then
      out[#out + 1] = candidate
    end
  end
  return out
end

---What a first word may be that <Tab> offers: the rulesets of the vault, the ids, the families, the parts.
---@param arg_lead string
---@return string[]
function M.target_candidates(arg_lead)
  local argtypes = require("lib.nvim.bindings.usercmd.composer.argtypes")
  local ops = require("rules.vault_ops")
  local out = {}
  local ok, ctx = pcall(ops.context)
  if ok and ctx then
    vim.list_extend(out, prefix(ops.ruleset_names(ctx), arg_lead))
  end
  vim.list_extend(out, prefix(ops.PARTS, arg_lead))
  for _, name in ipairs({ "RULES_FAMILY", "RULES_ID" }) do
    local found, list = pcall(argtypes.get(name).complete, arg_lead, {})
    if found and type(list) == "table" then
      vim.list_extend(out, list)
    end
  end
  return out
end

---Register `RULES_VAULT_TARGET`. Safe to call twice.
---@return nil
function M.register_types()
  local argtypes = require("lib.nvim.bindings.usercmd.composer.argtypes")
  argtypes.register("RULES_VAULT_TARGET", {
    desc = "Ruleset of the vault, rule id or family; a part word alone also works",
    validate = function(raw)
      return true, raw, nil
    end,
    complete = function(arg_lead)
      return M.target_candidates(arg_lead)
    end,
  })
end

local TARGET = {
  name = "target",
  type = "RULES_VAULT_TARGET",
  optional = true,
  desc = "Ruleset, rule id or family (default: the ruleset of this buffer)",
}

local PART = {
  name = "part",
  type = "STRING",
  enum = require("rules.vault_ops").PARTS,
  optional = true,
  desc = "Part of the ruleset (default: rules); a rule id or a family has none",
  enum_desc = require("rules.vault_ops").PART_DESC,
}

local REL = {
  name = "rel",
  bool = true,
  desc = "Write the path relative to the folder of the current file instead of absolute",
}

local LINK = {
  name = "link",
  bool = true,
  desc = "Copy a Markdown link, [DEP-06](path), instead of the bare path",
}

---The flags of each route, also read by the handlers (`rules.ui.cmd.words` takes a command line apart the way the
---composer does).
---@type table<string, table[]>
M.FLAGS = {
  clipboard = { REL, LINK },
  cdx = { REL },
  create = {
    { name = "git", bool = true, desc = "Run git init in the folder (no remote, nothing is pushed)" },
    { name = "yes", bool = true, desc = "Skip the question that lists what will happen" },
    { name = "force", bool = true, desc = "Make a vault although another one is in use" },
  },
}

---@param verb string
---@param desc string
---@param flags? table[]
---@return table route
local function target_route(verb, desc, flags)
  return {
    path = { verb },
    args = { TARGET, PART },
    flags = flags,
    desc = desc,
    run = function(ctx)
      cmd()[verb](ctx)
    end,
  }
end

---The route list of `:RulesVault`.
---@return table[] routes
function M.routes()
  return {
    target_route(
      "open",
      "Open the rule file of an id, the folder of a family, or a part of a ruleset (rules, layouts, catalogs, all)"
    ),
    target_route(
      "clipboard",
      "Copy the path of a rule file, a family folder or a part of a ruleset to the + register",
      M.FLAGS.clipboard
    ),
    target_route("link", "Insert a Markdown link to a rule, a family or a part at the cursor, relative to the current file"),
    target_route("find", "Pick a file by name in the ruleset of a rule id, in a family or in a part, through pickers.nvim"),
    target_route("grep", "Search the content of the files of a ruleset, a family or a part through pickers.nvim"),
    target_route("tree", "Show a ruleset as a tree: family, then rules, with counts per family and a marker on the retired ones"),
    target_route("cdx", "Copy a prompt for an agent session that names the rule, family or part to the + register", M.FLAGS.cdx),
    {
      path = { "create" },
      args = {
        {
          name = "dir",
          type = "PATH",
          optional = true,
          desc = "Folder of the new vault (asked for when missing); an existing one is used as it is",
        },
        {
          name = "name",
          type = "STRING",
          optional = true,
          desc = "Name of the first ruleset under rulesets/ (default: default)",
        },
      },
      flags = M.FLAGS.create,
      desc = "Make a rules vault: folder, README, .rules.json, .gitattributes, .gitignore, CI and a first ruleset. "
        .. "Lists what happens and the setup() step that is left to you, then asks (--yes skips it). "
        .. "Never overwrites a file, never adds a remote",
      run = function(ctx)
        cmd().create(ctx)
      end,
    },
  }
end

return M
