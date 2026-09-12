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
        },
        desc = "Sweep one rule family (--family=PREFIX) across PATH (default: cwd)",
        run = function(ctx)
          if not ctx.flags.family then
            vim.notify("[rules.nvim] :Rules check needs --family=<PREFIX>, e.g. --family=DEP", vim.log.levels.ERROR)
            return
          end
          require("rules").check_family(ctx.flags.family, ctx.args.path)
        end,
      },
    },
  })
end

return M
