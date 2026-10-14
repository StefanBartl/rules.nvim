---@module 'rules'
---@brief Public entry point: `setup()` plus the programmatic API the
--- `:Rules` command is built on.

local config = require("rules.config")
local loader = require("rules.engine.loader")
local runner = require("rules.engine.runner")
local waivers = require("rules.engine.waivers")
local gate = require("rules.engine.gate")
local notify = require("rules.util.notify")

---@type table<"critical"|"recommended"|"nice-to-have", integer>
local ZERO_SEVERITY = { critical = 0, recommended = 0, ["nice-to-have"] = 0 }

local M = {}

---@param opts Rules.Opts|nil
---@return nil
function M.setup(opts)
  config.setup(opts)
  require("rules.bindings.usrcmds").setup()
end

--- Load every configured ruleset, notifying on any parse error or ID collision.
---@return Rules.ParsedRule[]
function M.load_rules()
  local rules, errors = loader.load(config.get().rulesets)
  for _, err in ipairs(errors) do
    notify.warn(err)
  end
  return rules
end

--- This root's waivers, notifying (not raising) on a malformed waivers file.
---@param root string
---@return Rules.Waivers
local function load_waivers(root)
  local repo_waivers, err = waivers.load(root)
  if err then
    notify.warn(err)
  end
  return repo_waivers
end

--- Host policy for a run, from `setup()`.
---@return Rules.RunOpts
local function run_opts()
  return { lua_predicates = config.get().lua_predicates }
end

--- Shared by `check_family`/`check_family_json`: load rules and this root's
--- waivers (`.rules-waivers.json`, see `docs/BINDINGS.md`), then run one
--- family. Warns when `family_prefix` matches zero loaded rules -- a family
--- prefix is derived from loaded rule ids, so that is always a mistake
--- (typo, or a ruleset not loaded/migrated yet), never a legitimate empty
--- result; mirrors the warning `run_gate_results` already gives via
--- `gate.unknown_families`.
---@param family_prefix string
---@param path string|nil
---@return Rules.Result[]
local function run_family(family_prefix, path)
  local root = path or vim.fn.getcwd()
  local rules = M.load_rules()
  if #gate.unknown_families(rules, { family_prefix }) > 0 then
    notify.warn(("--family=%q matches no loaded rule -- typo in the prefix, or not loaded/migrated yet"):format(family_prefix))
  end
  return runner.check_family(rules, family_prefix, root, load_waivers(root), run_opts())
end

--- Shared by `run_gate`/`run_gate_json`.
---@param gate_name string
---@param path string|nil
---@param diff_ref string|nil  scope results to `git diff --name-only <ref>`
---@return Rules.Result[]|nil results
---@return string|nil error
local function run_gate_results(gate_name, path, diff_ref)
  local families = config.get().gates[gate_name]
  if not families then
    local known = vim.tbl_keys(config.get().gates)
    table.sort(known)
    local hint = #known > 0 and ("configured gates: " .. table.concat(known, ", ")) or "no gates configured"
    return nil, ("unknown gate %q (%s)"):format(gate_name, hint)
  end

  local root = path or vim.fn.getcwd()
  local rules = M.load_rules()
  for _, family in ipairs(gate.unknown_families(rules, families)) do
    notify.warn(
      ("gate %q: family %q matches no loaded rule -- typo in gates config, or not migrated yet"):format(gate_name, family)
    )
  end
  local results = gate.run(rules, families, root, load_waivers(root), run_opts())

  if diff_ref then
    local changed, err = gate.diff_files(root, diff_ref)
    if not changed then
      return nil, err
    end
    results = gate.scope_to_diff(results, changed)
  end

  return results, nil
end

--- Run one rule family against a path and report it (quickfix + buffer).
---@param family_prefix string
---@param path string|nil  defaults to the current working directory
---@return Rules.Result[]
function M.check_family(family_prefix, path)
  local results = run_family(family_prefix, path)
  require("rules.report.quickfix").set(results)
  require("rules.report.buffer").open(results)
  return results
end

--- Run one rule family against a path for headless/CI use: no quickfix, no
--- buffer, just the results plus a ready-to-print JSON string and an exit
--- code. Never quits Neovim itself — a CI script decides what to do with
--- the exit code (e.g. `vim.cmd("cquit " .. code)`), so calling this
--- interactively is harmless.
---@param family_prefix string
---@param path string|nil  defaults to the current working directory
---@return string json
---@return 0|1 exit_code
---@return Rules.Result[] results
function M.check_family_json(family_prefix, path)
  local results = run_family(family_prefix, path)
  local json = require("rules.report.json")
  return json.encode(results), json.exit_code(results), results
end

--- Run a configured gate (`setup({ gates = { <name> = {family_prefix, ...} } })`)
--- and report it (quickfix + buffer), same as `check_family` but over
--- several families at once. On an unknown gate name or a `--diff` git
--- error, notifies and returns nil rather than reporting an empty run.
---@param gate_name string
---@param path string|nil  defaults to the current working directory
---@param diff_ref string|nil  scope to `git diff --name-only <ref>` against `path`
---@return Rules.Result[]|nil
function M.run_gate(gate_name, path, diff_ref)
  local results, err = run_gate_results(gate_name, path, diff_ref)
  if not results then
    notify.error(err)
    return nil
  end
  require("rules.report.quickfix").set(results)
  require("rules.report.buffer").open(results)
  return results
end

--- `run_gate`'s headless/CI counterpart, mirroring `check_family_json`: no
--- quickfix, no buffer, no process exit -- just `(json, exit_code, results)`,
--- or `(nil, nil, nil, error)` on an unknown gate name or a `--diff` git error.
---@param gate_name string
---@param path string|nil
---@param diff_ref string|nil
---@return string|nil json
---@return 0|1|nil exit_code
---@return Rules.Result[]|nil results
---@return string|nil error
function M.run_gate_json(gate_name, path, diff_ref)
  local results, err = run_gate_results(gate_name, path, diff_ref)
  if not results then
    return nil, nil, nil, err
  end
  local json = require("rules.report.json")
  return json.encode(results), json.exit_code(results), results, nil
end

--- Find one loaded rule by its exact id, for jumping straight to its source
--- (`:Rules show <id>`) without running a whole family check.
---@param id string
---@return Rules.ParsedRule|nil
function M.find_rule(id)
  for _, rule in ipairs(M.load_rules()) do
    if rule.id == id then
      return rule
    end
  end
  return nil
end

--- Build the reading documents ("catalogs") of a ruleset in the one-file-per-rule form from its
--- layouts (`docs/RULESET-FORMAT.md`), or with `check` only say which are out of date (CI).
--- Without `path` every directory in `setup({ rulesets })` is built. Headless/CI use: no
--- notification, no quit -- `(results, errors, exit_code)`, the exit code is `1` when a document is
--- stale (check), a layout cannot be filled or has an output it must not write (a layout, a rule file,
--- another layout's output, a place outside the ruleset, a file nobody generated), or the ruleset has
--- load errors. `adopt` lets a layout replace an existing output that is not a generated document (a
--- hand-written one); nothing else.
---@param path string|nil  a ruleset directory
---@param opts? Rules.CatalogOpts
---@return Rules.CatalogResult[] results
---@return string[] errors
---@return 0|1 exit_code
function M.catalog(path, opts)
  opts = opts or {}
  local catalog = require("rules.engine.catalog")
  local roots = {}
  if path then
    roots[1] = path
  else
    for _, ruleset in ipairs(config.get().rulesets) do
      if vim.fn.isdirectory(require("lib.nvim.cross.fs.expand_path")(ruleset)) == 1 then
        roots[#roots + 1] = ruleset
      end
    end
  end
  local results, errors, code = {}, {}, 0
  for _, root in ipairs(roots) do
    local built, load_errors = catalog.build(root, opts)
    for _, result in ipairs(built) do
      results[#results + 1] = result
      if result.status == "stale" or result.status == "error" or #result.problems > 0 then
        code = 1
      end
    end
    for _, err in ipairs(load_errors) do
      errors[#errors + 1] = err
      code = 1
    end
  end
  return results, errors, code
end

---@class Rules.FamilyStats
---@field total integer
---@field checked integer  rules with a `check` field
---@field manual integer  rules with no `check` field
---@field severity table<"critical"|"recommended"|"nice-to-have", integer>

---@class Rules.Stats
---@field total integer  every loaded rule, across every family
---@field families table<string, Rules.FamilyStats>  keyed by family prefix

--- A structural overview of every loaded rule -- no check runs, just catalog
--- metadata (`:Rules stats`). Answers "how big is this ruleset, how much of
--- it is automated" without the multi-hour whole-catalog sweep `:Rules
--- check`/`:Rules gate` deliberately never offer.
---@return Rules.Stats
function M.stats()
  local rules = M.load_rules()
  ---@type table<string, Rules.FamilyStats>
  local families = {}

  for _, rule in ipairs(rules) do
    local family = runner.family_of(rule.id)
    local stats = families[family]
    if not stats then
      stats = { total = 0, checked = 0, manual = 0, severity = vim.deepcopy(ZERO_SEVERITY) }
      families[family] = stats
    end
    stats.total = stats.total + 1
    if rule.check then
      stats.checked = stats.checked + 1
    else
      stats.manual = stats.manual + 1
    end
    stats.severity[rule.severity] = stats.severity[rule.severity] + 1
  end

  return { total = #rules, families = families }
end

return M
