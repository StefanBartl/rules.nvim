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
---@return "pass"|"fail"|"error" status
---@return Rules.Finding[] findings
function M.run(spec, root)
  ---@type string[]
  local candidates = spec.path and { spec.path } or (spec.paths or {})

  -- Neither `path` nor a non-empty `paths` given: before `paths` existed,
  -- this shape (a typo'd field name, e.g. `Path = "..."`) crashed loudly --
  -- `root .. "/" .. spec.path` on a nil `spec.path` -- which `checks.run`
  -- propagates uncaught. `candidates == {}` below would otherwise degrade
  -- that into a silent, wrong verdict: `file_absent` returns "pass" with no
  -- findings (indistinguishable from a correctly-configured check that
  -- genuinely found the forbidden file absent), and `file_exists` returns a
  -- "fail" whose file path ends in "/?" -- misleading either way, on exactly
  -- the class of rule ("this file must never exist") where a silently
  -- vacuous check is the worst possible failure mode. Matches
  -- lua_predicate.lua's "has no `fn`" handling: a malformed spec is a loud
  -- "error", not a quiet wrong answer.
  if #candidates == 0 then
    return "error", { { file = root, line = 1, text = "file_exists/file_absent check has no `path` or `paths`" } }
  end
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
