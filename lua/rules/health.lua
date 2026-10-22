---@module 'rules.health'
---@brief `:checkhealth rules` diagnostics.
---@description
--- Read-only: loads whatever rulesets are configured to report load errors
--- and ID collisions early, but never mutates anything.

local M = {}

---@class Rules.Health.Report
---@field ok fun(message: string)
---@field warn fun(message: string, advice?: string[])
---@field error fun(message: string, advice?: string[])
---@field info fun(message: string)

---@param origin table<string, string>
---@return string
local function origins(origin)
  local names = vim.tbl_keys(origin)
  table.sort(names)
  local parts = {}
  for _, name in ipairs(names) do
    parts[#parts + 1] = ("%s (%s)"):format(name, origin[name])
  end
  return table.concat(parts, ", ")
end

---@param res Rules.Settings
---@param report Rules.Health.Report
local function report_files(res, report)
  local settings = require("rules.settings")
  local NAME = require("rules.config.file").NAME
  local cwd = vim.fn.getcwd()
  if res.project and res.project.exists and #res.project.problems == 0 then
    report.ok(("project file %s loaded (setup() still wins over it)"):format(res.project.path))
  elseif not (res.project and res.project.exists) then
    report.info(("no %s in %s (optional: rulesets, gates and agent settings of this project)"):format(NAME, cwd))
  end
  if res.vault_file and res.vault_file.exists and #res.vault_file.problems == 0 then
    report.ok(("vault file %s loaded"):format(res.vault_file.path))
  end
  for _, n in ipairs(res.problems) do
    report.error(settings.format(n, false), { "Fix the file named in this message; nothing is loaded from it until it is valid" })
  end
  for _, n in ipairs(res.warnings) do
    report.warn(settings.format(n, false))
  end
end

---@param res Rules.Settings
---@param report Rules.Health.Report
local function report_vault(res, report)
  local settings = require("rules.settings")
  if not res.vault then
    report.info("no vault configured (optional): " .. settings.NO_VAULT_HINT)
    return
  end
  local where = settings.VAULT_WHERE[res.vault.source]
  if not res.vault.exists then
    report.error(("vault %s (from %s) is not a folder"):format(res.vault.root, where))
    return
  end
  if res.vault.file_problem then
    report.error("the vault's own .rules.json cannot be used (see above): no ruleset is offered by it")
    return
  end
  report.ok(("vault %s (from %s)"):format(res.vault.root, where))
  local names = {}
  for _, folder in ipairs(res.vault.loaded or res.vault.rulesets) do
    names[#names + 1] = vim.fs.basename(folder)
  end
  if #names == 0 then
    report.warn(("the vault offers no ruleset (no folder under %s/)"):format(settings.VAULT_SUBDIR))
  else
    report.info(("the vault offers %d ruleset(s): %s"):format(#names, table.concat(names, ", ")))
  end
  local git = require("rules.vault").git_state(res.vault.root)
  if git == nil then
    return
  end
  if git.error then
    report.warn("vault git state unknown: " .. git.error)
  elseif not git.repo then
    report.info(
      git.inside and ("the vault is not a git repository of its own (it lies inside %s)"):format(git.inside)
        or "the vault is not a git repository"
    )
  elseif git.clean then
    report.ok("the vault is a git repository, clean (nothing to commit)")
  else
    report.warn(("the vault is a git repository with %d uncommitted path(s)"):format(git.changes), {
      "Commit (and push) the vault so other machines see the same rules",
    })
  end
end

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

  local report = { ok = ok, warn = warn, error = error_, info = info }
  local settings = require("rules.settings")
  local res = settings.resolve({ project = vim.fn.getcwd(), need_vault = true })

  start("rules.nvim: settings files")
  report_files(res, report)

  start("rules.nvim: vault")
  report_vault(res, report)

  start("rules.nvim: rulesets")
  local rules = {}
  if #res.problems > 0 then
    error_("rulesets are not loaded: the settings above cannot be used")
  elseif #res.rulesets == 0 then
    info(settings.nothing_configured(res) or "no rulesets configured")
  else
    info(("rulesets come from: %s"):format(res.origin.rulesets))
    for _, entry in ipairs(res.entries) do
      if not entry.trusted then
        warn(("ruleset %s is not trusted (%s): its lua_predicate checks do not run"):format(entry.name, entry.why or "?"), {
          "Trust it with setup({ trust = { <folder> } }) if you know the rules",
        })
      end
    end
    if next(res.origin.gates) then
      info("gates: " .. origins(res.origin.gates))
    end
    local agent_set = {}
    for key, layer in pairs(res.origin.agent) do
      if layer ~= "default" then
        agent_set[key] = layer
      end
    end
    if next(agent_set) then
      info("agent settings: " .. origins(agent_set))
    end
    local errors
    rules, errors = require("rules.engine.loader").load(res.rulesets)
    if #errors == 0 then
      ok(("%d rule(s) loaded from %d ruleset path(s), no errors"):format(#rules, #res.rulesets))
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
    local repo_waivers, werr = waivers.load_entries(vim.fn.getcwd())
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
      local expired = waivers.expired(repo_waivers, waivers.today(nil))
      if #expired > 0 then
        warn(("%d waiver(s) in cwd expired and suppress nothing: %s"):format(#expired, table.concat(expired, ", ")))
      end
    end

    -- Only a project that keeps accepted agent verdicts gets this section.
    local verdicts = require("rules.engine.verdicts")
    local repo_verdicts, verr = verdicts.load(vim.fn.getcwd())
    if verr or next(repo_verdicts) ~= nil then
      start("rules.nvim: verdicts")
      if verr then
        warn(verr)
      else
        local orphaned = verdicts.orphaned(repo_verdicts, rules)
        if #orphaned == 0 then
          ok(("%d verdict(s) in cwd, all match a loaded rule"):format(vim.tbl_count(repo_verdicts)))
        else
          warn(
            ("%d verdict(s) in cwd, %d orphaned (no matching rule -- retired or mistyped id): %s"):format(
              vim.tbl_count(repo_verdicts),
              #orphaned,
              table.concat(orphaned, ", ")
            )
          )
        end
      end
    end
  end

  require("lib.nvim.bindings.usercmd.composer").checkhealth("Rules")
end

return M
