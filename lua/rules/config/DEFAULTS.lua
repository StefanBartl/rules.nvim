---@module 'rules.config.DEFAULTS'
---@brief Plugin defaults.
---@description
--- Deliberately empty `rulesets`: rules.nvim ships no opinions of its own —
--- see the README's "Why no bundled rules". Without a configured ruleset,
--- `:Rules check` finds zero rules and says so, rather than falling back to
--- anything bundled.
---
--- Deliberately no `vault`: rules.nvim does not know where your vault lives. Without `vault` the engine reads
--- `$RULES_VAULT` and a `vault` in the project's `.rules.json`, and otherwise says that no vault is configured
--- instead of guessing a path (`rules.settings`).

---@class Rules.AgentScope
---@field include string[]  globs of the files a rule of this family looks at

---@class Rules.AgentOpts
---@field backends string[]  allow-list of backends; empty: local only (nothing is sent to a cloud provider)
---@field models string[]  the models the run dialog offers (free text stays possible)
---@field batch_size integer  rules per request
---@field max_context_bytes integer  the most file content one request carries
---@field deny string[]  globs of paths that are never put into a request
---@field scopes table<string, Rules.AgentScope>  per family: where its rules look; no scope means not sent

---@class Rules.Opts
---@field rulesets string[]  files or directories to load fenced `rule` blocks from; `@vault/<name>` names a ruleset of the vault
---@field gates table<string, string[]>  named groups of family prefixes, e.g. `{ release = {"REL"} }`; see `:Rules gate`
---@field lua_predicates boolean  whether `lua_predicate` checks may run. Default true: your own rulesets in
---   your own Neovim. Set false to run a ruleset you do not trust -- its predicates then report `error`
---@field vault string|nil  the folder of the rules-vault (rulesets under `rulesets/`); nil: `$RULES_VAULT`, then the
---   `vault` of a project `.rules.json`
---@field agent Rules.AgentOpts  how an agent run is planned (the same block as in `.rules.json`)

---@type Rules.Opts
return {
  rulesets = {},
  gates = {},
  lua_predicates = true,
  vault = nil,
  agent = {
    backends = {},
    models = {},
    batch_size = 8,
    max_context_bytes = 60000,
    deny = {},
    scopes = {},
  },
}
