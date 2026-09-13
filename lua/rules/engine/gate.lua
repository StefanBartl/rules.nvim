---@module 'rules.engine.gate'
---@brief A gate runs several rule families together as one named bundle
--- (e.g. "release"), optionally scoped to a git diff.
---@description
--- Deliberately the one place in this plugin that runs more than one family
--- at once — `runner.check_family` stays one-family-at-a-time by design (see
--- its own doc comment), but a gate is by definition a curated bundle
--- someone chose on purpose, not the "whole catalog sweep" that produced the
--- unreadable multi-hour report this plugin is modeled against. Which
--- families make up a gate is entirely user config (`setup({ gates = {...} })`)
--- -- this plugin ships no opinion on what "release-ready" means, same as it
--- ships no bundled rules.

local runner = require("rules.engine.runner")

local M = {}

--- Run every family in `families` against `root` and concatenate the
--- results into one list.
---@param rules Rules.ParsedRule[]
---@param families string[]
---@param root string
---@param waivers Rules.Waivers|nil
---@return Rules.Result[]
function M.run(rules, families, root, waivers)
  local results = {}
  for _, family in ipairs(families) do
    vim.list_extend(results, runner.check_family(rules, family, root, waivers))
  end
  return results
end

--- Family prefixes in `families` that match zero rules in `rules` -- almost
--- always a typo in `setup({ gates = {...} })` or a family that hasn't been
--- migrated into fenced `rule` blocks yet. A gate silently running fewer
--- families than configured is exactly the "no error, no warning, just a
--- smaller result" failure mode this plugin's own rules (e.g. `LLS-31`)
--- warn against -- so this is surfaced, not swallowed. Pure data, no
--- `vim.notify` here: engine modules report facts, `init.lua` decides how
--- to tell the user (same split as `loader.lua`/`waivers.lua`).
---@param rules Rules.ParsedRule[]
---@param families string[]
---@return string[] unknown  family prefixes with 0 matching rules, in input order
function M.unknown_families(rules, families)
  local present = {}
  for _, r in ipairs(rules) do
    present[runner.family_of(r.id)] = true
  end
  local unknown = {}
  for _, family in ipairs(families) do
    if not present[family] then
      unknown[#unknown + 1] = family
    end
  end
  return unknown
end

--- The set of files changed relative to `git_ref`, as absolute normalized
--- paths -- for scoping a gate to "just this diff" (`review`'s default).
--- Includes brand-new untracked files too (`git diff` alone omits them,
--- but a new file is exactly the kind of thing a review should look at).
---@param root string
---@param git_ref string
---@return table<string, true>|nil changed  nil on a git error
---@return string|nil error
function M.diff_files(root, git_ref)
  local diff_out = vim.fn.system({ "git", "-C", root, "diff", "--name-only", git_ref })
  if vim.v.shell_error ~= 0 then
    return nil, "git diff failed: " .. vim.trim(diff_out)
  end

  -- Best-effort: if this fails for some reason, still scope to the tracked
  -- diff above rather than failing the whole gate over untracked-file detection.
  local untracked_out = vim.fn.system({ "git", "-C", root, "ls-files", "--others", "--exclude-standard" })
  if vim.v.shell_error ~= 0 then
    untracked_out = ""
  end

  local rel_paths = vim.split(diff_out, "\n", { trimempty = true })
  vim.list_extend(rel_paths, vim.split(untracked_out, "\n", { trimempty = true }))

  local changed = {}
  for _, rel in ipairs(rel_paths) do
    changed[vim.fs.normalize(vim.fn.fnamemodify(root .. "/" .. rel, ":p"))] = true
  end
  return changed, nil
end

--- Narrow a run's results to only the findings that touch a changed file.
--- A rule whose findings are all outside the diff reports "pass" instead --
--- deliberate: a diff-scoped review answers "did this change introduce a
--- problem", not "does this repo have any standing problems", which is what
--- an unscoped `:Rules check`/the `release` gate are for.
---@param results Rules.Result[]
---@param changed table<string, true>
---@return Rules.Result[]
function M.scope_to_diff(results, changed)
  local scoped = {}
  for _, res in ipairs(results) do
    if res.status == "fail" or res.status == "error" then
      local kept = {}
      for _, f in ipairs(res.findings) do
        if changed[vim.fs.normalize(vim.fn.fnamemodify(f.file, ":p"))] then
          kept[#kept + 1] = f
        end
      end
      if #kept > 0 then
        scoped[#scoped + 1] = { rule = res.rule, status = res.status, findings = kept }
      else
        scoped[#scoped + 1] = { rule = res.rule, status = "pass", findings = {} }
      end
    else
      scoped[#scoped + 1] = res
    end
  end
  return scoped
end

return M
