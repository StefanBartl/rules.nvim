---@module 'rules.config.schema'
---@brief The one schema of the settings: `setup()`, the `.rules.json` of a project and the `.rules.json` of a vault.
---@description
--- The same keys mean the same thing everywhere; what differs is which keys a place may carry (`KEYS`):
---
---   rulesets        list of strings   ruleset files or folders (`@vault/<name>` names a ruleset of the vault)
---   gates           name -> list      named groups of family prefixes
---   agent           object            `backends`, `models`, `batch_size`, `max_context_bytes`, `deny`,
---                                     `scopes` (family -> `{ include = { ... } }`)
---   vault           string            the folder of the rules-vault (`setup()` and a project file only)
---   lua_predicates  boolean           `setup()` only: a file in a repository must not decide what code may run
---
--- `check` never raises and never guesses: it returns the part that is valid, every problem with the dotted key it
--- belongs to, and every key it does not know. What to do with a problem is the caller's: `setup()` drops the key
--- and warns (ERR-22), a file is refused as a whole (`rules.settings`: fail loudly). A problem drops only what is
--- wrong: a bad field of `agent` does not take the valid ones (`deny`) with it.
---
--- `[]` and `{}` are two things in a JSON file and the same empty table in Lua. A decoded file is checked with
--- `strict` (`vim.json.decode` marks an empty object with `vim.empty_dict()`, so an empty table without the mark was
--- an array): `[]` is not an object and `{}` is not a list. `setup()` and a call cannot say which they mean, they get
--- either.
---
--- Not its job: reading a file (`rules.config.file`), merging the places (`rules.settings`).

local M = {}

---@alias Rules.Config.Scope "setup"|"project"|"vault"|"call"

---Which top-level keys each place may carry. `call` is the options table of the headless entry points
---(`rules.api`, `scripts/rules.lua`): its keys are checked like the others, an unknown one is not looked for.
---@type table<Rules.Config.Scope, string[]>
M.KEYS = {
  setup = { "rulesets", "gates", "lua_predicates", "vault", "agent" },
  project = { "rulesets", "gates", "agent", "vault" },
  vault = { "rulesets", "gates", "agent" },
  call = { "rulesets", "gates", "agent", "vault" },
}

---The keys of the `agent` object.
M.AGENT_KEYS = { "backends", "models", "batch_size", "max_context_bytes", "deny", "scopes" }

---A hint for a key that is known elsewhere but not in this place.
---@type table<Rules.Config.Scope, table<string, string>>
local ELSEWHERE = {
  project = {
    lua_predicates = "is a setup() option only (a file in a repository must not decide what code may run)",
  },
  vault = {
    lua_predicates = "is a setup() option only (a file must not decide what code may run)",
    vault = "belongs in setup() or a project file (a vault does not name another vault)",
  },
}

---Whether the current `check` reads a decoded JSON file (see the module header). Set by `M.check` for its duration.
local strict = false

---An empty table that `vim.json.decode` made from `{}` (not from `[]`).
---@param value table
---@return boolean
local function is_empty_dict(value)
  return next(value) == nil and getmetatable(value) == getmetatable(vim.empty_dict())
end

---Whether a value is an object (or, for Lua, an empty table).
---@param value any
---@return boolean
local function is_object(value)
  if type(value) ~= "table" then
    return false
  end
  if next(value) ~= nil then
    return not vim.islist(value)
  end
  return not strict or is_empty_dict(value)
end

---Whether a value is a list (or, for Lua, an empty table).
---@param value any
---@return boolean
local function is_list(value)
  if type(value) ~= "table" then
    return false
  end
  if next(value) ~= nil then
    return vim.islist(value)
  end
  return not (strict and is_empty_dict(value))
end

---@class Rules.Config.Problem
---@field key string  dotted path of the key, "" for the document itself
---@field message string

---@class Rules.Config.Unknown
---@field key string
---@field hint string|nil  "did you mean x?" or a reason

---@class Rules.Config.Checked
---@field clean table  the valid part
---@field problems Rules.Config.Problem[]
---@field unknown Rules.Config.Unknown[]

---@param value any
---@return string
local function describe(value)
  if value == vim.NIL then
    return "null"
  end
  local kind = type(value)
  if kind == "table" then
    if next(value) == nil then
      return strict and (is_empty_dict(value) and "an empty object" or "an empty list") or "an empty list"
    end
    return vim.islist(value) and "a list" or "an object"
  elseif kind == "string" then
    return value == "" and "an empty string" or "a string"
  elseif kind == "number" then
    return "a number"
  elseif kind == "boolean" then
    return "a boolean"
  end
  return kind
end

---The nearest known name, when one is close enough to be a typo.
---@param name string
---@param known string[]
---@return string|nil
local function nearest(name, known)
  local levenshtein = require("lib.lua.strings.distance").levenshtein
  local best, best_distance = nil, nil
  for _, candidate in ipairs(known) do
    local d = levenshtein(name, candidate)
    if d <= 3 and (best_distance == nil or d < best_distance) then
      best, best_distance = candidate, d
    end
  end
  return best
end

---@param table_ table
---@param known string[]
---@param prefix string
---@param scope Rules.Config.Scope
---@param out Rules.Config.Unknown[]
local function find_unknown(table_, known, prefix, scope, out)
  local set = {}
  for _, key in ipairs(known) do
    set[key] = true
  end
  local names = {}
  for key in pairs(table_) do
    if not set[key] then
      names[#names + 1] = tostring(key)
    end
  end
  table.sort(names)
  for _, name in ipairs(names) do
    local hint = prefix == "" and ELSEWHERE[scope] and ELSEWHERE[scope][name] or nil
    if not hint then
      local near = nearest(name, known)
      hint = near and ("did you mean %s?"):format(near) or nil
    end
    out[#out + 1] = { key = prefix .. name, hint = hint }
  end
end

---A list of non-empty strings (an empty list is fine).
---@param value any
---@param key string
---@param problems Rules.Config.Problem[]
---@return string[]|nil
local function string_list(value, key, problems)
  if not is_list(value) then
    problems[#problems + 1] = { key = key, message = ("must be a list of strings, got %s"):format(describe(value)) }
    return nil
  end
  local out = {}
  for i, item in ipairs(value) do
    if type(item) ~= "string" or item == "" then
      problems[#problems + 1] =
        { key = key, message = ("must be a list of non-empty strings; item %d is %s"):format(i, describe(item)) }
      return nil
    end
    out[i] = item
  end
  return out
end

---@param value any
---@param key string
---@param problems Rules.Config.Problem[]
---@return integer|nil
local function whole_number(value, key, problems)
  if type(value) ~= "number" or value ~= value or value < 1 or value % 1 ~= 0 or value == math.huge then
    problems[#problems + 1] = { key = key, message = ("must be a whole number of 1 or more, got %s"):format(describe(value)) }
    return nil
  end
  return value
end

---@param value any
---@param problems Rules.Config.Problem[]
---@return table<string, string[]>|nil
local function gates(value, problems)
  if not is_object(value) then
    problems[#problems + 1] =
      { key = "gates", message = ("must map a gate name to a list of family prefixes, got %s"):format(describe(value)) }
    return nil
  end
  local out, ok = {}, true
  local names = {}
  for name in pairs(value) do
    names[#names + 1] = name
  end
  table.sort(names, function(a, b)
    return tostring(a) < tostring(b)
  end)
  for _, name in ipairs(names) do
    if type(name) ~= "string" or name == "" then
      problems[#problems + 1] = { key = "gates", message = "a gate needs a name (a non-empty string)" }
      ok = false
    else
      local list = string_list(value[name], "gates." .. name, problems)
      if list then
        out[name] = list
      else
        ok = false
      end
    end
  end
  return ok and out or nil
end

---@param value any
---@param problems Rules.Config.Problem[]
---@param unknown Rules.Config.Unknown[]
---@param scope Rules.Config.Scope
---@return table|nil
local function agent(value, problems, unknown, scope)
  if not is_object(value) then
    problems[#problems + 1] = { key = "agent", message = ("must be an object, got %s"):format(describe(value)) }
    return nil
  end
  if scope ~= "call" then
    find_unknown(value, M.AGENT_KEYS, "agent.", scope, unknown)
  end
  -- a field that is wrong is dropped on its own, with its problem: the valid ones (`deny`!) stay
  local out = {}
  for _, name in ipairs({ "backends", "models", "deny" }) do
    if value[name] ~= nil then
      out[name] = string_list(value[name], "agent." .. name, problems)
    end
  end
  for _, name in ipairs({ "batch_size", "max_context_bytes" }) do
    if value[name] ~= nil then
      out[name] = whole_number(value[name], "agent." .. name, problems)
    end
  end
  if value.scopes ~= nil then
    local scopes = value.scopes
    if not is_object(scopes) then
      problems[#problems + 1] =
        { key = "agent.scopes", message = ("must map a family to { include = { ... } }, got %s"):format(describe(scopes)) }
    else
      local families = {}
      for family in pairs(scopes) do
        families[#families + 1] = family
      end
      table.sort(families, function(a, b)
        return tostring(a) < tostring(b)
      end)
      out.scopes = {}
      for _, family in ipairs(families) do
        local key = "agent.scopes." .. tostring(family)
        local scope_value = scopes[family]
        if type(family) ~= "string" or family == "" then
          problems[#problems + 1] = { key = "agent.scopes", message = "a scope needs a family name (a non-empty string)" }
        elseif not is_object(scope_value) then
          problems[#problems + 1] =
            { key = key, message = ("must be { include = { ... } }, got %s"):format(describe(scope_value)) }
        else
          if scope ~= "call" then
            find_unknown(scope_value, { "include" }, key .. ".", scope, unknown)
          end
          if scope_value.include == nil then
            problems[#problems + 1] = { key = key, message = "needs include (a list of globs); no scope means not sent" }
          else
            local include = string_list(scope_value.include, key .. ".include", problems)
            if include then
              out.scopes[family] = { include = include }
            end
          end
        end
      end
    end
  end
  return out
end

---@param value any
---@param problems Rules.Config.Problem[]
---@return string|nil
local function vault(value, problems)
  if type(value) ~= "string" or value == "" then
    problems[#problems + 1] =
      { key = "vault", message = ("must be a folder path (a non-empty string), got %s"):format(describe(value)) }
    return nil
  end
  return value
end

---@param value any
---@param problems Rules.Config.Problem[]
---@return boolean|nil
local function lua_predicates(value, problems)
  if type(value) ~= "boolean" then
    problems[#problems + 1] = { key = "lua_predicates", message = ("must be a boolean, got %s"):format(describe(value)) }
    return nil
  end
  return value
end

---@param value any
---@param scope Rules.Config.Scope
---@return Rules.Config.Checked
local function check_table(value, scope)
  ---@type Rules.Config.Checked
  local result = { clean = {}, problems = {}, unknown = {} }
  if not is_object(value) then
    result.problems[1] = { key = "", message = ("must be an object, got %s"):format(describe(value)) }
    return result
  end
  if scope ~= "call" then
    find_unknown(value, M.KEYS[scope], "", scope, result.unknown)
  end
  local allowed = {}
  for _, key in ipairs(M.KEYS[scope]) do
    allowed[key] = true
  end
  local clean, problems = result.clean, result.problems
  if allowed.rulesets and value.rulesets ~= nil then
    clean.rulesets = string_list(value.rulesets, "rulesets", problems)
  end
  if allowed.gates and value.gates ~= nil then
    clean.gates = gates(value.gates, problems)
  end
  if allowed.agent and value.agent ~= nil then
    clean.agent = agent(value.agent, problems, result.unknown, scope)
  end
  if allowed.vault and value.vault ~= nil then
    clean.vault = vault(value.vault, problems)
  end
  if allowed.lua_predicates and value.lua_predicates ~= nil then
    clean.lua_predicates = lua_predicates(value.lua_predicates, problems)
  end
  return result
end

---Check a settings table.
---@param value any  the decoded file, the `setup()` argument or the options of a call
---@param scope Rules.Config.Scope
---@param from_json? boolean  `value` was decoded from a JSON file: `[]` and `{}` are told apart (see the module header)
---@return Rules.Config.Checked
function M.check(value, scope, from_json)
  strict = from_json == true
  local result = check_table(value, scope)
  strict = false
  return result
end

---An unknown key as text: `name (did you mean x?)`.
---@param unknown Rules.Config.Unknown
---@return string
function M.unknown_text(unknown)
  return unknown.hint and ("%s (%s)"):format(unknown.key, unknown.hint) or unknown.key
end

return M
