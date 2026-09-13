---@module 'rules.health'
---@brief `:checkhealth rules` diagnostics.
---@description
--- Read-only: loads whatever rulesets are configured to report load errors
--- and ID collisions early, but never mutates anything.

local M = {}

---@return nil
function M.check()
  local health = vim.health or require("health")
  local start = health.start or health.report_start
  local ok = health.ok or health.report_ok
  local warn = health.warn or health.report_warn
  local error_ = health.error or health.report_error
  local info = health.info or health.report_info

  start("rules.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    ok("Neovim " .. tostring(vim.version()))
  else
    warn("rules.nvim targets Neovim 0.10+", { "Upgrade Neovim to 0.10+" })
  end

  if pcall(require, "lib.nvim.bindings.usercmd.composer") then
    ok("lib.nvim.bindings.usercmd.composer -- the :Rules command")
  else
    error_("lib.nvim missing -- :Rules will not be registered", { 'Install "StefanBartl/lib.nvim"' })
    return
  end

  -- LUA-05: lib.nvim itself is a hard dependency, but these two submodules
  -- are recent enough (2026-07-16) that an older lib.nvim checkout could
  -- plausibly predate them -- a bare `require` failure deep inside
  -- fswalk.lua/parser.lua would otherwise surface as a cryptic
  -- "module not found" at first actual use, not here where it's
  -- actionable.
  if pcall(require, "lib.nvim.fs.collect_recursive") then
    ok("lib.nvim.fs.collect_recursive -- the ruleset/repo file walker")
  else
    error_(
      "lib.nvim.fs.collect_recursive missing -- :Rules check/gate will fail on the first file walk",
      { "Update lib.nvim (this submodule is required since rules.nvim's REL-31 fix)" }
    )
  end
  if pcall(require, "lib.lua.error") then
    ok("lib.lua.error -- pcall wrapping for ruleset/waiver parsing")
  else
    error_(
      "lib.lua.error missing -- ruleset/waiver parsing will fail",
      { "Update lib.nvim (this submodule is required since rules.nvim's ERR-05/06 fix)" }
    )
  end

  start("rules.nvim: rulesets")
  local config = require("rules.config").get()
  local rules = {}
  if #config.rulesets == 0 then
    info("no rulesets configured -- setup({ rulesets = {...} }) to point at your own rules")
  else
    local errors
    rules, errors = require("rules.engine.loader").load(config.rulesets)
    if #errors == 0 then
      ok(("%d rule(s) loaded from %d ruleset path(s), no errors"):format(#rules, #config.rulesets))
    else
      warn(("%d rule(s) loaded, %d error(s)"):format(#rules, #errors))
      for _, e in ipairs(errors) do
        warn("  " .. e)
      end
    end
  end

  if #rules > 0 then
    start("rules.nvim: waivers")
    local waivers = require("rules.engine.waivers")
    local repo_waivers, werr = waivers.load(vim.fn.getcwd())
    if werr then
      warn(werr)
    elseif next(repo_waivers) == nil then
      info("no .rules-waivers.json in cwd, or it has no entries")
    else
      local count = vim.tbl_count(repo_waivers)
      local orphaned = waivers.orphaned(repo_waivers, rules)
      if #orphaned == 0 then
        ok(("%d waiver(s) in cwd, all match a loaded rule"):format(count))
      else
        warn(
          ("%d waiver(s) in cwd, %d orphaned (no matching rule -- retired or mistyped id): %s"):format(
            count,
            #orphaned,
            table.concat(orphaned, ", ")
          )
        )
      end
    end
  end

  require("lib.nvim.bindings.usercmd.composer").checkhealth("Rules")
end

return M
