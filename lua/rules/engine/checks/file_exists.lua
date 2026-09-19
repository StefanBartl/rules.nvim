---@module 'rules.engine.checks.file_exists'
---@brief Check types "file_exists" and "file_absent": a required path is (or
--- is not) present relative to the checked root.

local M = {}

---@class Rules.Check.FileExists
---@field type "file_exists"|"file_absent"
---@field path string|nil  relative to the checked root
---@field paths string[]|nil  any-of a list of relative paths -- for a file
---  with more than one accepted spelling (e.g. `stylua.toml` and the equally
---  valid `.stylua.toml`, both read by stylua itself). Same `pattern`/
---  `patterns` singular-or-list convention `grep` uses; `path` and `paths`
---  are mutually exclusive, `path` wins if both are somehow given.

---@param spec Rules.Check.FileExists
---@param root string
---@return "pass"|"fail" status
---@return Rules.Finding[] findings
function M.run(spec, root)
  ---@type string[]
  local candidates = spec.path and { spec.path } or (spec.paths or {})
  local label = spec.path or table.concat(candidates, " or ")

  local found_full = nil
  for _, p in ipairs(candidates) do
    local full = root .. "/" .. p
    if vim.fn.filereadable(full) == 1 or vim.fn.isdirectory(full) == 1 then
      found_full = full
      break
    end
  end

  if spec.type == "file_absent" then
    if found_full then
      return "fail", { { file = found_full, line = 1, text = label .. " must not exist" } }
    end
    return "pass", {}
  end

  if found_full then
    return "pass", {}
  end
  return "fail", { { file = root .. "/" .. (spec.path or candidates[1] or "?"), line = 1, text = label .. " is missing" } }
end

return M
