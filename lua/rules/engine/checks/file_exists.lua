---@module 'rules.engine.checks.file_exists'
---@brief Check types "file_exists" and "file_absent": a required path is (or
--- is not) present relative to the checked root.

---@description
--- A path with a `*` in it is a glob, matched against the files under the
--- root: `*` stays inside one path segment, a `**` segment spans any number of
--- directories (none included). That is what a catalog written for every
--- repo needs -- `lua/*/health.lua` when the module name differs per plugin.
--- The match runs over the same literal directory walk `grep` uses, never
--- over `vim.fn.glob`, which reads the *root* as a pattern too (`~`, `[`):
--- a Windows 8.3 short name in the root would make it silently match nothing.
--- A glob therefore sees files only, and nothing under the directories the
--- walk skips (`.git`, `.deps`, `.claude`).

local fswalk = require("rules.engine.fswalk")
local glob_lib = require("rules.engine.glob")

local M = {}

---@class Rules.Check.FileExists
---@field type "file_exists"|"file_absent"
---@field path string|nil  relative to the checked root; a glob when it contains `*`
---@field paths string[]|nil  any-of a list of relative paths -- for a file
---  with more than one accepted spelling (e.g. `stylua.toml` and the equally
---  valid `.stylua.toml`, both read by stylua itself). Same `pattern`/
---  `patterns` singular-or-list convention `grep` uses; `path` and `paths`
---  are mutually exclusive, `path` wins if both are somehow given.

--- The first file under `root` matching `glob`, or nil.
---@param glob string  relative, "/"-separated
---@param root string
---@param ctx table|nil
---@return string|nil full
local function first_glob_match(glob, root, ctx)
  local prefix = root:gsub("\\", "/"):gsub("/+$", "") .. "/"
  local glob_segments = glob_lib.compile(glob)
  for _, file in ipairs(fswalk.cached_files(root, ctx)) do
    if file:sub(1, #prefix) == prefix then
      local parts = glob_lib.split(file:sub(#prefix + 1))
      if glob_lib.match(glob_segments, parts) then
        return file
      end
    end
  end
  return nil
end

---@param spec Rules.Check.FileExists
---@param root string
---@param ctx table|nil  shared cache for one `check_family` run; a glob
---   reuses the file listing `grep` rules of the same run already took
---@return "pass"|"fail"|"error" status
---@return Rules.Finding[] findings
function M.run(spec, root, ctx)
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
  -- PRIN-25: `spec` is a raw table from a user-authored Markdown file --
  -- validate each candidate is actually a string before it drives the
  -- `root .. "/" .. p` concatenation below (a wrong-typed value, e.g. a
  -- table or boolean, would otherwise throw uncaught).
  for _, p in ipairs(candidates) do
    if type(p) ~= "string" then
      return "error", { { file = root, line = 1, text = "file_exists/file_absent check's `path`/`paths` must be string(s)" } }
    end
  end
  local label = spec.path or table.concat(candidates, " or ")

  local found_full = nil
  for _, p in ipairs(candidates) do
    if p:find("*", 1, true) then
      found_full = first_glob_match(p, root, ctx)
    else
      local full = root .. "/" .. p
      if vim.fn.filereadable(full) == 1 or vim.fn.isdirectory(full) == 1 then
        found_full = full
      end
    end
    if found_full then
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
