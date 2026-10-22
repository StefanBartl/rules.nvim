---@module 'rules.config'
---@brief Merge setup() options over DEFAULTS.
---@description
--- This is the `setup()` layer only. What a run actually uses is `rules.settings.resolve()`: `setup()` on top of the
--- `.rules.json` of the project and of the vault (ranked there, in one place), on top of these defaults.
---
--- `setup()` is validated by `rules.config.schema` (one schema for setup, the project file, the vault file and a
--- call: scopes, strict JSON lists and objects, hints), and the part that passes is the one layer of a
--- `lib.lua.config.new` object over `DEFAULTS` (`get()`). Its merge rules are the ones `rules.config.merge` states:
--- a list is replaced whole, `gates` and `agent.scopes` merge by name, the keys of a UI by action. The object
--- never sees a rejected value, so its own check (a schema inferred from `DEFAULTS`) has nothing to add; it is the
--- `copy` of the defaults and the merge that it contributes.
---
--- `rules.settings.resolve()` does **not** read its layers from this object, on purpose: the files and the options of
--- a call differ per run (a project root, a headless call), `rulesets` is not merged but taken from the highest layer
--- that names it (with the vault as a special case), every value remembers the layer it came from (`origin`), and
--- a file layer is checked with the strict JSON schema, which a schema inferred from `DEFAULTS` cannot say.
--- `rules.config.merge` therefore stays: `resolve` stacks the layers with it.

local DEFAULTS = require("rules.config.DEFAULTS")
local schema = require("rules.config.schema")
local keys_mod = require("rules.config.keys")
local notify = require("rules.util.notify")

local M = {}

---The one persistent layer, `setup()`, over the defaults. `vault` has no default (unset means `$RULES_VAULT`, then
---a project file), the keys of the form take a key, a list of keys or `false`.
local store = require("lib.lua.config").new(DEFAULTS, {
  name = "rules",
  schema = {
    vault = "string",
    ["keys.form.toggle"] = "keymap",
    ["keys.form.accept"] = "keymap",
    ["keys.form.submit"] = "keymap",
    ["keys.form.close"] = "keymap",
    ["keys.form.cancel"] = "keymap",
    ["keys.form.help"] = "keymap",
  },
  merge = { gates = "entries", ["agent.scopes"] = "entries" },
  notify = function(message)
    notify.warn(("setup(): %s"):format(message))
  end,
})

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
  store.setup(explicit)
  warn_key_conflicts(store.get().keys.form)
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
  return store.get()
end

--- The keys `setup()` set (validated), nothing from the defaults: the layer `rules.settings` ranks above the files.
--- A live reference, like `get`; do not change it.
---@return table
function M.explicit()
  return explicit
end

return M
