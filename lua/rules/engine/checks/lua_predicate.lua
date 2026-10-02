---@module 'rules.engine.checks.lua_predicate'
---@brief Check type "lua_predicate": an escape hatch for anything the other
--- three primitives cannot express, supplied as a plain function.

-- ERR-05/06: `lib.lua.error.safe_call` instead of a hand-rolled `pcall` --
-- correctly forwards both of `spec.fn`'s return values on success (a bare
-- `pcall` does the same, but `safe_call` also gives a full traceback on
-- failure instead of a bare error string, valuable here since `spec.fn` is
-- arbitrary user code that can fail arbitrarily deep).
local safe_error = require("lib.lua.error")
local errline = require("rules.engine.checks.errline")
local sandbox = require("rules.util.sandbox")

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

--- A predicate is arbitrary Lua, and a parsed one is created in an empty
--- environment (see `rules.util.sandbox`): it only gets `vim`, `string`, `io`
--- back when the host trusts predicates, and says so loudly when it does not --
--- the rule reports `error`, it never silently drops out of the run.
---@param spec Rules.Check.LuaPredicate
---@param root string
---@param _ctx table|nil  unused; the shared cache is `grep`'s
---@param opts { lua_predicates?: boolean }|nil  `lua_predicates = false` refuses to run
---   a predicate; absent means trusted, as before
---@return "pass"|"fail"|"error" status
---@return Rules.Finding[] findings
function M.run(spec, root, _ctx, opts)
  if type(spec.fn) ~= "function" then
    return "error", { { file = root, line = 1, text = "lua_predicate check has no `fn`" } }
  end

  if opts and opts.lua_predicates == false then
    return "error", { { file = root, line = 1, text = "predicate not trusted (lua_predicates is off)" } }
  end
  sandbox.rebind(spec.fn)

  local ok, passed, findings_or_msg = safe_error.safe_call(spec.fn, root)
  if not ok then
    -- `passed.message` is a full multi-line `debug.traceback()` string --
    -- embedding it as-is would crash `report/buffer.lua`'s render instead
    -- of showing this friendly error (see errline.lua).
    return "error", { { file = root, line = 1, text = "lua_predicate error: " .. errline.first_line(passed.message) } }
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
