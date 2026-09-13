---@module 'rules.bindings.usrcmds'
---@brief The `:Rules <subcommand>` verb, built via lib.nvim's composer.

local M = {}

--- Register two argtypes with the shared composer registry so `--family=`
--- and a gate's `<name>` complete against whatever is actually loaded/
--- configured right now, instead of offering nothing. Validation stays
--- permissive (any string passes) -- an unknown family/gate name is already
--- reported by `check_family`/`run_gate` at dispatch time (an empty result
--- set, or `gate.unknown_families`'s warning), so duplicating that check
--- here would just be a second place for the two answers to disagree.
---@return nil
local function register_argtypes()
  local argtypes = require("lib.nvim.bindings.usercmd.composer.argtypes")
  local runner = require("rules.engine.runner")

  argtypes.register("RULES_FAMILY", {
    validate = function(raw)
      return true, raw, nil
    end,
    complete = function(arg_lead)
      local seen = {}
      for _, rule in ipairs(require("rules").load_rules()) do
        seen[runner.family_of(rule.id)] = true
      end
      local families = vim.tbl_keys(seen)
      table.sort(families)
      return argtypes.prefix(families, arg_lead)
    end,
  })

  argtypes.register("RULES_GATE", {
    validate = function(raw)
      return true, raw, nil
    end,
    complete = function(arg_lead)
      local names = vim.tbl_keys(require("rules.config").get().gates)
      table.sort(names)
      return argtypes.prefix(names, arg_lead)
    end,
  })

  argtypes.register("RULES_ID", {
    validate = function(raw)
      return true, raw, nil
    end,
    complete = function(arg_lead)
      local ids = {}
      for _, rule in ipairs(require("rules").load_rules()) do
        ids[#ids + 1] = rule.id
      end
      table.sort(ids)
      return argtypes.prefix(ids, arg_lead)
    end,
  })
end

--- Create the `:Rules` verb.
---@return nil
function M.setup()
  register_argtypes()
  local composer = require("lib.nvim.bindings.usercmd.composer")

  composer.verb("Rules", {
    desc = "rules.nvim: dry-run one rule family against your own rulesets",
    routes = {
      {
        path = { "check" },
        args = { { name = "path", type = "DIR", optional = true } },
        flags = {
          { name = "family", type = "RULES_FAMILY" },
          { name = "format", type = "STRING", values = { "json" } },
        },
        desc = "Sweep one rule family (--family=PREFIX) across PATH (default: cwd), --format=json for machine-readable output",
        run = function(ctx)
          if not ctx.flags.family then
            vim.notify("[rules.nvim] :Rules check needs --family=<PREFIX>, e.g. --family=DEP", vim.log.levels.ERROR)
            return
          end
          if ctx.flags.format == "json" then
            local json = require("rules").check_family_json(ctx.flags.family, ctx.args.path)
            print(json)
          else
            require("rules").check_family(ctx.flags.family, ctx.args.path)
          end
        end,
      },
      {
        path = { "gate" },
        args = {
          { name = "name", type = "RULES_GATE" },
          { name = "path", type = "DIR", optional = true },
        },
        flags = {
          { name = "diff", type = "STRING" },
          { name = "format", type = "STRING", values = { "json" } },
        },
        desc = "Run a configured gate (setup({ gates = {...} })), --diff=<git-ref> to scope to that diff",
        run = function(ctx)
          if not ctx.args.name then
            vim.notify("[rules.nvim] :Rules gate needs a name, e.g. :Rules gate release", vim.log.levels.ERROR)
            return
          end
          if ctx.flags.format == "json" then
            local json, _, _, err = require("rules").run_gate_json(ctx.args.name, ctx.args.path, ctx.flags.diff)
            if err then
              vim.notify("[rules.nvim] " .. err, vim.log.levels.ERROR)
            else
              print(json)
            end
          else
            require("rules").run_gate(ctx.args.name, ctx.args.path, ctx.flags.diff)
          end
        end,
      },
      {
        path = { "show" },
        args = { { name = "id", type = "RULES_ID" } },
        desc = "Jump to one rule's source location by id, e.g. :Rules show DEP-06",
        run = function(ctx)
          local rule = require("rules").find_rule(ctx.args.id)
          if not rule then
            vim.notify(("[rules.nvim] no loaded rule with id %q"):format(ctx.args.id), vim.log.levels.ERROR)
            return
          end
          vim.cmd.edit(vim.fn.fnameescape(rule.source_file))
          vim.api.nvim_win_set_cursor(0, { rule.source_line, 0 })
        end,
      },
      {
        path = { "stats" },
        flags = { { name = "format", type = "STRING", values = { "json" } } },
        desc = "Structural overview of every loaded rule: per-family totals, automated-vs-manual, severity -- no check run",
        run = function(ctx)
          local stats = require("rules").stats()
          if ctx.flags.format == "json" then
            print(vim.json.encode(stats))
          else
            require("rules.report.stats").open(stats)
          end
        end,
      },
    },
  })
end

return M
