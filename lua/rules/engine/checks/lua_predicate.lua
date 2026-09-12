---@module 'rules.engine.checks.lua_predicate'
---@brief Check type "lua_predicate": an escape hatch for anything the other
--- three primitives cannot express, supplied as a plain function.

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

  local ok, passed, findings_or_msg = pcall(spec.fn, root)
  if not ok then
    return "error", { { file = root, line = 1, text = "lua_predicate error: " .. tostring(passed) } }
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
