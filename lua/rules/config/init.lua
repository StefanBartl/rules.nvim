---@module 'rules.config'
---@brief Merge setup() options over DEFAULTS.
---@description
--- This is the `setup()` layer only. What a run actually uses is `rules.settings.resolve()`: `setup()` on top of the
--- `.rules.json` of the project and of the vault (ranked there, in one place), on top of these defaults.

local DEFAULTS = require("rules.config.DEFAULTS")
local schema = require("rules.config.schema")
local merge = require("rules.config.merge")
local keys_mod = require("rules.config.keys")
local notify = require("rules.util.notify")

local M = {}

---@type Rules.Opts
local state = vim.deepcopy(DEFAULTS)

---What `setup()` set, validated: only the keys it named. `settings.resolve` ranks these above the files; the
---defaults are not in here.
---@type table
local explicit = {}

--- ERR-50: unknown-key detection runs before the merge -- a typo'd top-
--- level option (`ruleset` for `rulesets`) must not vanish silently into
--- the default; the same mechanism that discards a bad *value* (ERR-22)
--- discarded a bad *key* with no notification at all.
---@param unknown Rules.Config.Unknown[]
---@return nil
local function warn_unknown_keys(unknown)
  if #unknown == 0 then
    return
  end
  local names = {}
  for _, entry in ipairs(unknown) do
    names[#names + 1] = schema.unknown_text(entry)
  end
  table.sort(names)
  notify.warn(("setup(): unknown option(s) ignored: %s"):format(table.concat(names, ", ")))
end

--- ERR-22: an invalid config value degrades to its default instead of
--- propagating to crash something downstream later (a `loader.load` or
--- `gate.run` call site), where the real cause -- a typo in `setup({...})`
--- -- is much harder to trace back to.
---@param opts table
---@return table validated  only the keys that passed validation
local function validate(opts)
  if type(opts) ~= "table" then
    notify.warn(("setup() expects a table, got %s -- ignoring, falling back to defaults"):format(type(opts)))
    return {}
  end

  local checked = schema.check(opts, "setup")
  warn_unknown_keys(checked.unknown)
  for _, problem in ipairs(checked.problems) do
    notify.warn(("setup(): %s %s -- ignoring, falling back to default"):format(problem.key, problem.message))
  end
  return checked.clean
end

--- Two actions on one key: the form binds them in a fixed order and the later one wins, so the other one does not work.
--- Said at `setup()`, not found out at the first `<Space>` in the form. The keys stay as set (the choice is the user's).
---@param form table<string, string|string[]|false>
---@return nil
local function warn_key_conflicts(form)
  local order = table.concat(schema.FORM_ACTIONS, ", ")
  for _, conflict in ipairs(keys_mod.conflicts(form, schema.FORM_ACTIONS)) do
    local who = table.concat(conflict.actions, ", ")
    local text = "setup(): keys.form: %s share the key %s; only the one the form binds last works (order: %s)"
    notify.warn(text:format(who, conflict.key, order) .. " -- give one of them another key, or false")
  end
end

---@param opts Rules.Opts|nil
---@return nil
function M.setup(opts)
  if opts == nil then
    opts = {}
  end
  explicit = validate(opts)
  state = vim.deepcopy(DEFAULTS)
  for key, value in pairs(explicit) do
    if key == "agent" then
      state.agent = merge.agent(DEFAULTS.agent, value)
    elseif key == "gates" then
      state.gates = merge.gates(DEFAULTS.gates, value)
    elseif key == "keys" then
      state.keys = merge.keys(DEFAULTS.keys, value)
    else
      state[key] = vim.deepcopy(value)
    end
  end
  warn_key_conflicts(state.keys.form)
  -- the settings of the last run were resolved with the old `setup()`
  require("rules.settings").reset()
end

--- ERR-54: a live reference to the internal state, not a copy -- every
--- current caller only reads it (`loader.load(config.get().rulesets)`,
--- `config.get().gates`), never mutates it. Stays this way rather than
--- `vim.deepcopy`-ing on every call: mutate it and you've mutated the
--- plugin's live config for the rest of the session, so don't.
---@return Rules.Opts
function M.get()
  return state
end

--- The keys `setup()` set (validated), nothing from the defaults: the layer `rules.settings` ranks above the files.
--- A live reference, like `get`; do not change it.
---@return table
function M.explicit()
  return explicit
end

return M
