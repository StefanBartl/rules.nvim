---@module 'rules.config'
---@brief Merge setup() options over DEFAULTS.

local DEFAULTS = require("rules.config.DEFAULTS")

local M = {}

---@type Rules.Opts
local state = vim.deepcopy(DEFAULTS)

---@param opts Rules.Opts|nil
---@return nil
function M.setup(opts)
  state = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), opts or {})
end

---@return Rules.Opts
function M.get()
  return state
end

return M
