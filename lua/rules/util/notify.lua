---@module 'rules.util.notify'
---@brief The single notifier for rules.nvim.
---@description
--- lib.nvim is a hard runtime dependency here already -- `bindings/usrcmds.lua`
--- builds the `:Rules` verb directly on `lib.nvim.bindings.usercmd.composer`,
--- no `pcall`/fallback around it -- so this needs none either, unlike a
--- plugin where `lib.nvim.notify` is soft-guarded (e.g. sessions.nvim).
---
--- Delivers via `lib.nvim.notify.popup` (a non-focus-stealing corner toast
--- plus a yankable history) tagged `source = "rules"`, so `:Rules messages`
--- (`bindings/usrcmds.lua`) and `:Lib notify history rules` both show every
--- message this plugin sends, from whichever of init.lua/config/bindings
--- sent it.

return require("lib.nvim.notify").create("[rules.nvim]", { popup = true, source = "rules" })
