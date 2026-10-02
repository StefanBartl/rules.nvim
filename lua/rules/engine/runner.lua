---@module 'rules.engine.runner'
---@brief Run one rule family (by ID prefix) against a root path.
---@description
--- Deliberately one family at a time, never "every loaded rule at once" — a
--- whole-catalog sweep in one command is exactly the shape that produced an
--- unreadable, multi-hour report in the real dry run this plugin is modeled
--- on (see the P5 write-up linked from the concept doc). `:Rules check` is
--- built on this one function precisely so it cannot offer that shortcut.

local checks = require("rules.engine.checks")

local M = {}

---@class Rules.Result
---@field rule Rules.ParsedRule
---@field status "pass"|"fail"|"error"|"manual"|"waived"
---@field findings Rules.Finding[]
---@field waiver_reason? string  set only when status is "waived" -- LLS-15: the
--- key is genuinely absent otherwise (see `check_family` below), not present
--- with a `nil` value, so `?` is the accurate form, not `string|nil`

---@class Rules.RunOpts
---@field lua_predicates? boolean|fun(rule: Rules.ParsedRule): boolean  whether a `lua_predicate`
---   may run: `false` reports it as an error instead, a function decides per rule (the
---   desktop host asks its trust store, keyed on the rule's `source_file`). Absent means
---   trusted -- inside one's own Neovim, pointed at one's own rulesets, that is the design

--- Whether `rule`'s predicate may run under `opts`.
---@param opts Rules.RunOpts|nil
---@param rule Rules.ParsedRule
---@return boolean
local function predicates_allowed(opts, rule)
  local policy = opts and opts.lua_predicates
  if policy == nil then
    return true
  end
  if type(policy) == "function" then
    return policy(rule) == true
  end
  return policy == true
end

--- The family of a rule id: its leading letters, e.g. "DEP" for "DEP-01".
---@param id string
---@return string
function M.family_of(id)
  return id:match("^(%a+)%-") or id
end

--- Run every rule whose family matches `family_prefix` against `root`.
---@param rules Rules.ParsedRule[]
---@param family_prefix string
---@param root string
---@param waivers Rules.Waivers|nil  `{ [rule_id] = reason }`; a waived rule
---   that would otherwise fail or error reports as "waived" instead
---@param opts Rules.RunOpts|nil
---@return Rules.Result[]
function M.check_family(rules, family_prefix, root, waivers, opts)
  waivers = waivers or {}
  local results = {}
  -- Shared across every rule in this run so a `grep` check (the common
  -- case) doesn't re-walk the filesystem and re-read the same files once
  -- per rule -- see `checks/grep.lua`'s `ctx` parameter.
  local ctx = {}
  for _, rule in ipairs(rules) do
    if M.family_of(rule.id) == family_prefix then
      local status, findings = checks.run(rule.check, root, ctx, { lua_predicates = predicates_allowed(opts, rule) })
      local reason = waivers[rule.id]
      if reason and (status == "fail" or status == "error") then
        results[#results + 1] = { rule = rule, status = "waived", findings = findings, waiver_reason = reason }
      else
        results[#results + 1] = { rule = rule, status = status, findings = findings }
      end
    end
  end
  return results
end

return M
