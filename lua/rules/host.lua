---@module 'rules.host'
---@brief The persistent engine process: `rules-export/1` over a line protocol on stdin and stdout.
---@description
--- `nvim --headless -u NONE -i NONE -n -l scripts/rules-host.lua` answers the contract many times in one process
--- (protocol and framing: `lib.nvim.contract.host`). The rulesets come from `$RULES_RULESETS` (paths separated by
--- `;`) and the gates from `$RULES_GATES` (`name=FAM,FAM;name=FAM`), like the command line's `--ruleset` and
--- `--gate`.

return require("lib.nvim.contract.host").make({
  api = require("rules.api"),
  call_opts = function()
    return require("rules.env").opts()
  end,
})
