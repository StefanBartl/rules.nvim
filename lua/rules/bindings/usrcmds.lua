---@module 'rules.bindings.usrcmds'
---@brief The `:Rules <subcommand>` verb, built via lib.nvim's composer.

local M = {}

--- Create the `:Rules` verb.
---@return nil
function M.setup()
  local composer = require("lib.nvim.bindings.usercmd.composer")

  composer.verb("Rules", {
    desc = "rules.nvim: dry-run one rule family against your own rulesets",
    routes = {
      {
        path = { "check" },
        args = { { name = "path", type = "DIR", optional = true } },
        flags = {
          { name = "family", type = "STRING" },
          { name = "format", type = "STRING" },
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
          { name = "name", type = "STRING" },
          { name = "path", type = "DIR", optional = true },
        },
        flags = {
          { name = "diff", type = "STRING" },
          { name = "format", type = "STRING" },
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
    },
  })
end

return M
