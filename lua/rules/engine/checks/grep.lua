---@module 'rules.engine.checks.grep'
---@brief Check type "grep": one or more Lua patterns searched line-by-line
--- under a root.
---@description
--- Deliberately Lua patterns, not a real regex engine and not an external
--- `rg` dependency — see docs/RULESET-FORMAT.md for why. `unless`, when
--- given, suppresses a hit on any line that also matches it — the escape
--- hatch for an already-fixed call site (e.g. `DEP-01`'s
--- `vim.uv or vim.loop` fallback, which itself contains the literal text
--- `vim.loop` and would otherwise flag itself).
---
--- `patterns` (a list) is the way to check "any of several calls" (e.g.
--- `DEP-04`'s `nvim_err_writeln()` *or* `nvim_out_write()`) — Lua patterns
--- have no `|` alternation at all, so a single pattern like
--- `"nvim_err_writeln%(|nvim_out_write%("` would not do what it looks like it
--- does: `|` is a literal character in a Lua pattern, not an operator, and
--- that pattern would silently match almost nothing rather than error. This
--- is a real mistake documented in this project's own history (a first-draft
--- port of a Python regex-alternation rule); `patterns` exists so nobody has
--- to rediscover it.

local fswalk = require("rules.engine.fswalk")

local M = {}

---@class Rules.Check.Grep
---@field type "grep"
---@field pattern string|nil  a single Lua pattern
---@field patterns string[]|nil  any-of a list of Lua patterns; use instead of `pattern` for more than one call site
---@field unless string|nil  Lua pattern; a hit on the same line is suppressed
---@field include string|nil  Lua pattern matched against the file path; default "%.lua$"

---@class Rules.Finding
---@field file string
---@field line integer
---@field text string

---@param line string
---@param spec Rules.Check.Grep
---@return boolean
local function line_hits(line, spec)
  if spec.pattern and line:find(spec.pattern) then
    return true
  end
  if spec.patterns then
    for _, p in ipairs(spec.patterns) do
      if line:find(p) then
        return true
      end
    end
  end
  return false
end

--- Run a `grep` check against every matching file under `root`.
---@param spec Rules.Check.Grep
---@param root string
---@return "pass"|"fail" status
---@return Rules.Finding[] findings
function M.run(spec, root)
  local include = spec.include or "%.lua$"
  local findings = {}

  for _, file in ipairs(fswalk.files(root)) do
    if file:match(include) then
      local ok, lines = pcall(vim.fn.readfile, file)
      if ok then
        for lnum, line in ipairs(lines) do
          if line_hits(line, spec) and not (spec.unless and line:find(spec.unless)) then
            findings[#findings + 1] = { file = file, line = lnum, text = vim.trim(line) }
          end
        end
      end
    end
  end

  return (#findings == 0) and "pass" or "fail", findings
end

return M
