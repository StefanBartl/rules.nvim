---@module 'rules'
---@brief Public entry point: `setup()` plus the programmatic API the
--- `:Rules` command is built on.

local config = require("rules.config")
local loader = require("rules.engine.loader")
local runner = require("rules.engine.runner")
local waivers = require("rules.engine.waivers")
local gate = require("rules.engine.gate")

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
    vim.notify("[rules.nvim] " .. err, vim.log.levels.WARN)
  end
  return rules
end

--- This root's waivers, notifying (not raising) on a malformed waivers file.
---@param root string
---@return Rules.Waivers
local function load_waivers(root)
  local repo_waivers, err = waivers.load(root)
  if err then
    vim.notify("[rules.nvim] " .. err, vim.log.levels.WARN)
  end
  return repo_waivers
end

--- Shared by `check_family`/`check_family_json`: load rules and this root's
--- waivers (`.rules-waivers.json`, see `docs/BINDINGS.md`), then run one
--- family.
---@param family_prefix string
---@param path string|nil
---@return Rules.Result[]
local function run_family(family_prefix, path)
  local root = path or vim.fn.getcwd()
  return runner.check_family(M.load_rules(), family_prefix, root, load_waivers(root))
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
  local results = gate.run(M.load_rules(), families, root, load_waivers(root))

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
    vim.notify("[rules.nvim] " .. err, vim.log.levels.ERROR)
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

return M
