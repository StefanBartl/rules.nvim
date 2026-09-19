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

--- ERR-02: this is the only place a findings table enters the system
--- without being constructed by the plugin itself -- `report/buffer.lua`
--- formats `f.line` with `%d`, a hard type requirement one bad entry from a
--- free-form predicate would otherwise break, with nothing pointing back at
--- the predicate that produced it.
---@param findings table
---@return boolean ok
---@return string|nil reason  set only when `ok` is false
local function validate_findings(findings)
  for i, f in ipairs(findings) do
    if type(f) ~= "table" or type(f.file) ~= "string" or type(f.line) ~= "number" or type(f.text) ~= "string" then
      return false, ("entry %d is not a {file, line, text} finding"):format(i)
    end
  end
  return true, nil
end

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
    local ok_findings, reason = validate_findings(findings_or_msg)
    if not ok_findings then
      return "error", { { file = root, line = 1, text = "lua_predicate returned a malformed finding: " .. reason } }
    end
    return "fail", findings_or_msg
  end
  if type(findings_or_msg) == "string" then
    return "fail", { { file = root, line = 1, text = findings_or_msg } }
  end
  return "fail", {}
end

return M
