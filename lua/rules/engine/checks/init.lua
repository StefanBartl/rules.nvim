---@module 'rules.engine.checks'
---@brief Dispatch a rule's `check.type` to its implementation.

local M = {}

---@type table<string, { run: fun(spec: table, root: string): string, Rules.Finding[] }>
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
---@return "pass"|"fail"|"error"|"manual" status
---@return Rules.Finding[] findings
function M.run(check, root)
  if check == nil then
    return "manual", {}
  end
  local impl = BY_TYPE[check.type]
  if not impl then
    return "error", { { file = root, line = 1, text = "unknown check type: " .. tostring(check.type) } }
  end
  return impl.run(check, root)
end

return M
