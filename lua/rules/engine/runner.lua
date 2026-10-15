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
---@field waiver_expires? string  "waived" only: the last day the waiver is valid, when it has one
---@field waiver_paths? string[]  "waived" only: the paths the waiver is limited to, when it has any
---@field partial_waiver? { reason: string, expires?: string, paths: string[], suppressed: integer }  a waiver limited to
--- paths covered some findings of a failing rule: `suppressed` of them; the status stays what the rest makes it
---@field expired_waiver? { reason: string, expires: string }  the rule has a waiver that ran out: it does not suppress
--- anything and the report says so (any status but "manual")

---@class Rules.RunOpts
---@field today? string  the date a waiver's expiry is judged against (`YYYY-MM-DD`); default: today's date (`waivers.clock`)
---@field lua_predicates? boolean|fun(rule: Rules.ParsedRule): boolean, string|nil  whether a `lua_predicate`
---   may run: `false` reports it as an error instead, a function decides per rule (the
---   desktop host asks its trust store, keyed on the rule's `source_file`; `rules` itself asks which ruleset
---   the file belongs to, `rules.settings`) and may give the reason as a second value, which is what the
---   error says. Absent means trusted -- a caller that passes no policy runs its own rulesets in its own Neovim

--- Whether `rule`'s predicate may run under `opts`.
---
--- Only a `lua_predicate` rule asks: the policy can be a host callback that
--- hashes files or reads a trust store, and consulting it for every `grep` and
--- `file_exists` rule of a family would repeat that work for an answer nothing
--- reads. A callback that throws means "not trusted" -- it must not abort the
--- family run, which reports one broken rule as `error` and carries on.
---@param opts Rules.RunOpts|nil
---@param rule Rules.ParsedRule
---@return boolean allowed
---@return string|nil reason  what the error says when it is not allowed (default: lua_predicates is off)
local function predicates_allowed(opts, rule)
  if not (rule.check and rule.check.type == "lua_predicate") then
    return true, nil
  end
  local policy = opts and opts.lua_predicates
  if policy == nil then
    return true, nil
  end
  if type(policy) == "function" then
    local ok, allowed, reason = pcall(policy, rule)
    if ok and allowed == true then
      return true, nil
    end
    return false, ok and type(reason) == "string" and reason or nil
  end
  return policy == true, nil
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
---@param waivers table<string, string|Rules.Waiver>|nil  `{ [rule_id] = reason }` or `{ [rule_id] = { reason, expires?,
---   paths? } }` (`waivers.load_entries`); a waived rule that would otherwise fail or error reports as "waived" instead,
---   unless the waiver is expired (it suppresses nothing and the result says so) or limited to `paths` (only the
---   findings in them are suppressed)
---@param opts Rules.RunOpts|nil
---@return Rules.Result[]
function M.check_family(rules, family_prefix, root, waivers, opts)
  waivers = waivers or {}
  local waiver_lib = require("rules.engine.waivers")
  local today = waiver_lib.today(opts and opts.today) or waiver_lib.clock()
  local relative
  local results = {}
  -- Shared across every rule in this run so a `grep` check (the common
  -- case) doesn't re-walk the filesystem and re-read the same files once
  -- per rule -- see `checks/grep.lua`'s `ctx` parameter.
  local ctx = {}
  for _, rule in ipairs(rules) do
    if M.family_of(rule.id) == family_prefix then
      local allowed, refusal = predicates_allowed(opts, rule)
      local status, findings = checks.run(rule.check, root, ctx, { lua_predicates = allowed, refusal = refusal })
      local waiver = waivers[rule.id]
      if type(waiver) == "string" then
        waiver = { reason = waiver }
      end
      local result = { rule = rule, status = status, findings = findings }
      if waiver and status ~= "manual" and waiver_lib.is_expired(waiver, today) then
        result.expired_waiver = { reason = waiver.reason, expires = waiver.expires }
      elseif waiver and (status == "fail" or status == "error") then
        local inside, outside = findings, {}
        if waiver.paths then
          relative = relative or waiver_lib.relativizer(root)
          inside = {}
          for _, finding in ipairs(findings) do
            local rel = relative(finding.file)
            if rel and waiver_lib.path_matches(waiver.paths, rel) then
              inside[#inside + 1] = finding
            else
              outside[#outside + 1] = finding
            end
          end
        end
        if #outside == 0 then
          result.status = "waived"
          result.waiver_reason = waiver.reason
          result.waiver_expires = waiver.expires
          result.waiver_paths = waiver.paths
        elseif #inside > 0 then
          result.findings = outside
          result.partial_waiver = { reason = waiver.reason, expires = waiver.expires, paths = waiver.paths, suppressed = #inside }
        end
      end
      results[#results + 1] = result
    end
  end
  return results
end

return M
