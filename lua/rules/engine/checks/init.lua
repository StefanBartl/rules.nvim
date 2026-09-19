---@module 'rules.engine.checks'
---@brief Dispatch a rule's `check.type` to its implementation.

-- ERR-05/06: `lib.lua.error.safe_call` instead of a hand-rolled `pcall` --
-- a traceback on failure instead of a bare error string, useful here since
-- `check` is a ruleset author's own data (an arbitrary Lua pattern, an
-- arbitrary `spec` shape) driving plugin code for the first time.
local safe_error = require("lib.lua.error")

local M = {}

--- LLS-11: a `fun(): T1, T2` multi-value return type inline inside a `{ ... }`
--- table type reads the comma after the first return type as ending that
--- field and starting an unnamed one, not as a second return value -- named
--- here instead of inline, same reasoning as the rule's own example.
---@class Rules.CheckImpl
---@field run fun(spec: table, root: string, ctx: table|nil): ("pass"|"fail"|"error"), Rules.Finding[]

---@type table<string, Rules.CheckImpl>
local BY_TYPE = {
  grep = require("rules.engine.checks.grep"),
  file_exists = require("rules.engine.checks.file_exists"),
  file_absent = require("rules.engine.checks.file_exists"),
  json_key_absent = require("rules.engine.checks.json_key"),
  lua_predicate = require("rules.engine.checks.lua_predicate"),
}

--- Run a rule's `check` against a root path.
---@param check table|nil
---@param root string
---@param ctx table|nil  shared cache for one `check_family` run; only
---   `grep` uses it today (memoized file listing/contents), other check
---   types ignore the extra argument
---@return "pass"|"fail"|"error"|"manual" status
---@return Rules.Finding[] findings
function M.run(check, root, ctx)
  if check == nil then
    return "manual", {}
  end
  local impl = BY_TYPE[check.type]
  if not impl then
    return "error", { { file = root, line = 1, text = "unknown check type: " .. tostring(check.type) } }
  end

  -- ERR-01: this is a system boundary -- a malformed ruleset-authored spec
  -- (an unescaped Lua pattern, a wrong-shaped `spec` table) must fail just
  -- this one rule, not abort the whole family run before any report opens.
  local ok, status, findings = safe_error.safe_call(impl.run, check, root, ctx)
  if not ok then
    return "error", { { file = root, line = 1, text = ("%s check crashed: %s"):format(check.type, status.message) } }
  end
  return status, findings
end

return M
