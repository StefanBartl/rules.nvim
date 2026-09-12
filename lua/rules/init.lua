---@module 'rules'
---@brief Public entry point: `setup()` plus the programmatic API the
--- `:Rules` command is built on.

local config = require("rules.config")
local loader = require("rules.engine.loader")
local runner = require("rules.engine.runner")
local waivers = require("rules.engine.waivers")

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

--- Shared by `check_family`/`check_family_json`: load rules and this root's
--- waivers (`.rules-waivers.json`, see `docs/BINDINGS.md`), then run one
--- family.
---@param family_prefix string
---@param path string|nil
---@return Rules.Result[]
local function run_family(family_prefix, path)
  local root = path or vim.fn.getcwd()
  local rules = M.load_rules()
  local repo_waivers, err = waivers.load(root)
  if err then
    vim.notify("[rules.nvim] " .. err, vim.log.levels.WARN)
  end
  return runner.check_family(rules, family_prefix, root, repo_waivers)
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

return M
