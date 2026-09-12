---@module 'rules.config.DEFAULTS'
---@brief Plugin defaults.
---@description
--- Deliberately empty `rulesets`: rules.nvim ships no opinions of its own —
--- see the README's "Why no bundled rules". Without a configured ruleset,
--- `:Rules check` finds zero rules and says so, rather than falling back to
--- anything bundled.

---@class Rules.Opts
---@field rulesets string[]  files or directories to load fenced `rule` blocks from

---@type Rules.Opts
return {
  rulesets = {},
}
