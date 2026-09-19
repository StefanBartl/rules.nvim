---@module 'rules.config'
---@brief Merge setup() options over DEFAULTS.

local DEFAULTS = require("rules.config.DEFAULTS")

local M = {}

---@type Rules.Opts
local state = vim.deepcopy(DEFAULTS)

---@param list any
---@return boolean
local function is_string_list(list)
  if not vim.islist(list) then
    return false
  end
  for _, v in ipairs(list) do
    if type(v) ~= "string" then
      return false
    end
  end
  return true
end

---@type table<string, true>
local KNOWN_KEYS = { rulesets = true, gates = true }

--- An unknown top-level key, with the nearest known one as a hint when
--- there is a plausible one -- same shape as lib.config's own
--- `describe_unknown`.
---@param key any
---@return string
local function describe_unknown(key)
  local levenshtein = require("lib.lua.strings.distance").levenshtein
  local name = tostring(key)
  local best, best_distance = nil, nil
  for known in pairs(KNOWN_KEYS) do
    local d = levenshtein(name, known)
    if d <= 3 and (best_distance == nil or d < best_distance) then
      best, best_distance = known, d
    end
  end
  return best and ("%s (did you mean %s?)"):format(name, best) or name
end

--- ERR-50: unknown-key detection runs before the merge -- a typo'd top-
--- level option (`ruleset` for `rulesets`) must not vanish silently into
--- the default; the same mechanism that discards a bad *value* (ERR-22)
--- discarded a bad *key* with no notification at all.
---@param opts table
---@return nil
local function warn_unknown_keys(opts)
  local unknown = {}
  for key in pairs(opts) do
    if not KNOWN_KEYS[key] then
      unknown[#unknown + 1] = describe_unknown(key)
    end
  end
  if #unknown > 0 then
    table.sort(unknown)
    vim.notify(("[rules.nvim] setup(): unknown option(s) ignored: %s"):format(table.concat(unknown, ", ")), vim.log.levels.WARN)
  end
end

--- ERR-22: an invalid config value degrades to its default instead of
--- propagating to crash something downstream later (a `loader.load` or
--- `gate.run` call site), where the real cause -- a typo in `setup({...})`
--- -- is much harder to trace back to.
---@param opts table
---@return table validated  only the keys that passed validation
local function validate(opts)
  if type(opts) ~= "table" then
    vim.notify(
      ("[rules.nvim] setup() expects a table, got %s -- ignoring, falling back to defaults"):format(type(opts)),
      vim.log.levels.WARN
    )
    return {}
  end

  warn_unknown_keys(opts)
  local out = {}

  if opts.rulesets ~= nil then
    if is_string_list(opts.rulesets) then
      out.rulesets = opts.rulesets
    else
      vim.notify(
        "[rules.nvim] setup({ rulesets = ... }) must be a list of strings -- ignoring, falling back to default",
        vim.log.levels.WARN
      )
    end
  end

  if opts.gates ~= nil then
    local gates_ok = type(opts.gates) == "table"
    if gates_ok then
      for name, families in pairs(opts.gates) do
        if type(name) ~= "string" or not is_string_list(families) then
          gates_ok = false
          break
        end
      end
    end
    if gates_ok then
      out.gates = opts.gates
    else
      vim.notify(
        '[rules.nvim] setup({ gates = ... }) must be { name = {"PREFIX", ...}, ... } -- ignoring, falling back to default',
        vim.log.levels.WARN
      )
    end
  end

  return out
end

---@param opts Rules.Opts|nil
---@return nil
function M.setup(opts)
  state = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), validate(opts or {}))
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

return M
