---@module 'rules.engine.checks.file_exists'
---@brief Check types "file_exists" and "file_absent": a required path is (or
--- is not) present relative to the checked root.

local M = {}

---@class Rules.Check.FileExists
---@field type "file_exists"|"file_absent"
---@field path string  relative to the checked root

---@param spec Rules.Check.FileExists
---@param root string
---@return "pass"|"fail" status
---@return Rules.Finding[] findings
function M.run(spec, root)
  local full = root .. "/" .. spec.path
  local exists = vim.fn.filereadable(full) == 1 or vim.fn.isdirectory(full) == 1

  if spec.type == "file_absent" then
    if exists then
      return "fail", { { file = full, line = 1, text = spec.path .. " must not exist" } }
    end
    return "pass", {}
  end

  if exists then
    return "pass", {}
  end
  return "fail", { { file = full, line = 1, text = spec.path .. " is missing" } }
end

return M
