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
local safe_error = require("lib.lua.error")

local M = {}

---@class Rules.Check.Grep
---@field type "grep"
---@field pattern string|nil  a single Lua pattern
---@field patterns string[]|nil  any-of a list of Lua patterns; use instead of `pattern` for more than one call site
---@field unless string|nil  Lua pattern; a hit on the same line is suppressed
---@field include string|nil  Lua pattern matched against the file path; default "%.lua$"
---@field excludes string[]|nil  any-of a list of Lua patterns matched against
---  the file path; a file matching any of these is skipped entirely (not
---  just this one hit) -- for a whole class of call site that is never the
---  hazard the rule means (TESTS/ fixtures exercising the very pattern being
---  checked for, a Neovim-free scripts/ that has no `vim.system` to reach
---  for). Same `pattern`/`patterns` singular-or-list convention as above.

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

--- Read `file`'s lines, memoized in `ctx` for the lifetime of one
--- `check_family` run -- most rules in a family default to `include` and so
--- end up reading the same files. `false` in the cache means "read already
--- failed", distinct from "not yet attempted" (a `nil` entry).
---@param file string
---@param ctx table|nil
---@return string[]|false lines  false when the file could not be read
---@return string|nil read_err
local function cached_readfile(file, ctx)
  if ctx then
    ctx.file_contents = ctx.file_contents or {}
    ctx.file_errors = ctx.file_errors or {}
    local cached = ctx.file_contents[file]
    if cached ~= nil then
      return cached, ctx.file_errors[file]
    end
  end

  -- ERR-05/06: `lib.lua.error.safe_call` instead of a hand-rolled `pcall`.
  -- ERR-60: deliberately an explicit `if`, not `ok and X or Y` -- the success
  -- value of `err` is `nil`, which is itself falsy, so that ternary shape
  -- would silently fall through to the failure branch every time regardless
  -- of `ok` (harmless today only because a caller never reads `err` unless
  -- `result == false`, which is exactly the kind of landmine this rule
  -- warns about).
  local ok, lines = safe_error.safe_call(vim.fn.readfile, file)
  local result, err
  if ok then
    result, err = lines, nil
  else
    result, err = false, lines.message
  end

  if ctx then
    ctx.file_contents[file] = result
    ctx.file_errors[file] = err
  end
  return result, err
end

--- Run a `grep` check against every matching file under `root`.
---@param spec Rules.Check.Grep
---@param root string
---@param ctx table|nil  shared cache for the current `check_family` run --
---   memoizes the file listing and file contents across rules in the same
---   family so a multi-rule sweep doesn't re-walk/re-read the whole tree
---   once per rule; see `runner.lua#check_family`
---@return "pass"|"fail" status
---@return Rules.Finding[] findings
function M.run(spec, root, ctx)
  local include = spec.include or "%.lua$"
  local findings = {}

  local files
  if ctx then
    ctx.file_list = ctx.file_list or {}
    files = ctx.file_list[root]
    if not files then
      files = fswalk.files(root)
      ctx.file_list[root] = files
    end
  else
    files = fswalk.files(root)
  end

  local function excluded(file)
    if not spec.excludes then
      return false
    end
    for _, p in ipairs(spec.excludes) do
      if file:find(p) then
        return true
      end
    end
    return false
  end

  for _, file in ipairs(files) do
    if file:match(include) and not excluded(file) then
      local lines, read_err = cached_readfile(file, ctx)
      if lines == false then
        -- A matching file that can't be read (permissions, deleted between the
        -- listing and this read, ...) is a fail, not a silent skip -- an
        -- unreadable file could be hiding the exact thing this rule checks for.
        findings[#findings + 1] = { file = file, line = 1, text = "could not read file: " .. tostring(read_err) }
      else
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
