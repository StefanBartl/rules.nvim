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

--- ERR-22: an invalid config value degrades to its default instead of
--- propagating to crash something downstream later (a `loader.load` or
--- `gate.run` call site), where the real cause -- a typo in `setup({...})`
--- -- is much harder to trace back to.
---@param opts table
---@return table validated  only the keys that passed validation
local function validate(opts)
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

---@return Rules.Opts
function M.get()
  return state
end

return M
