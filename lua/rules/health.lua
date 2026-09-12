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

  start("rules.nvim: rulesets")
  local config = require("rules.config").get()
  if #config.rulesets == 0 then
    info("no rulesets configured -- setup({ rulesets = {...} }) to point at your own rules")
  else
    local rules, errors = require("rules.engine.loader").load(config.rulesets)
    if #errors == 0 then
      ok(("%d rule(s) loaded from %d ruleset path(s), no errors"):format(#rules, #config.rulesets))
    else
      warn(("%d rule(s) loaded, %d error(s)"):format(#rules, #errors))
      for _, e in ipairs(errors) do
        warn("  " .. e)
      end
    end
  end

  require("lib.nvim.bindings.usercmd.composer").checkhealth("Rules")
end

return M
