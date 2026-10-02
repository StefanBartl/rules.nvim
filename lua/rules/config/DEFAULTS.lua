---@module 'rules.config.DEFAULTS'
---@brief Plugin defaults.
---@description
--- Deliberately empty `rulesets`: rules.nvim ships no opinions of its own —
--- see the README's "Why no bundled rules". Without a configured ruleset,
--- `:Rules check` finds zero rules and says so, rather than falling back to
--- anything bundled.

---@class Rules.Opts
---@field rulesets string[]  files or directories to load fenced `rule` blocks from
---@field gates table<string, string[]>  named groups of family prefixes, e.g. `{ release = {"REL"} }`; see `:Rules gate`
---@field lua_predicates boolean  whether `lua_predicate` checks may run. Default true: your own rulesets in
---   your own Neovim. Set false to run a ruleset you do not trust -- its predicates then report `error`

---@type Rules.Opts
return {
  rulesets = {},
  gates = {},
  lua_predicates = true,
}
