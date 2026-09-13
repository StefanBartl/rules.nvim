---@module 'rules.engine.checks.lua_predicate'
---@brief Check type "lua_predicate": an escape hatch for anything the other
--- three primitives cannot express, supplied as a plain function.

-- ERR-05/06: `lib.lua.error.safe_call` instead of a hand-rolled `pcall` --
-- correctly forwards both of `spec.fn`'s return values on success (a bare
-- `pcall` does the same, but `safe_call` also gives a full traceback on
-- failure instead of a bare error string, valuable here since `spec.fn` is
-- arbitrary user code that can fail arbitrarily deep).
local safe_error = require("lib.lua.error")

local M = {}

---@class Rules.Check.LuaPredicate
---@field type "lua_predicate"
---@field fn fun(root: string): boolean, (Rules.Finding[]|string)?

---@param spec Rules.Check.LuaPredicate
---@param root string
---@return "pass"|"fail"|"error" status
---@return Rules.Finding[] findings
function M.run(spec, root)
  if type(spec.fn) ~= "function" then
    return "error", { { file = root, line = 1, text = "lua_predicate check has no `fn`" } }
  end

  local ok, passed, findings_or_msg = safe_error.safe_call(spec.fn, root)
  if not ok then
    return "error", { { file = root, line = 1, text = "lua_predicate error: " .. passed.message } }
  end
  if passed then
    return "pass", {}
  end

  if type(findings_or_msg) == "table" then
    return "fail", findings_or_msg
  end
  if type(findings_or_msg) == "string" then
    return "fail", { { file = root, line = 1, text = findings_or_msg } }
  end
  return "fail", {}
end

return M
