---@module 'rules.config.merge'
---@brief How two layers of settings combine: what a higher layer replaces and what it adds to.
---@description
--- A value that is a list (`rulesets`, `backends`, `models`, `deny`, the families of a gate, `include`) is replaced as a
--- whole by the higher layer, never concatenated: a project that narrows `rulesets` must be able to take an entry away.
--- A table that names things (`gates` by gate name, `agent.scopes` by family) is merged by name: the higher layer
--- replaces the entries it names and leaves the rest. The scalars of `agent` (`batch_size`, `max_context_bytes`)
--- are replaced.
---
--- `vim.tbl_deep_extend` is not used on purpose: it treats an empty list as a table to merge into, so
--- `deny = {}` in a project could not clear a `deny` of the layer below.

local M = {}

---@param base table<string, string[]>|nil
---@param over table<string, string[]>|nil
---@return table<string, string[]>
function M.gates(base, over)
  local out = vim.deepcopy(base or {})
  for name, families in pairs(over or {}) do
    out[name] = vim.deepcopy(families)
  end
  return out
end

---@param base Rules.AgentOpts|table|nil
---@param over Rules.AgentOpts|table|nil
---@return table
function M.agent(base, over)
  local out = vim.deepcopy(base or {})
  for key, value in pairs(over or {}) do
    if key == "scopes" then
      out.scopes = out.scopes or {}
      for family, scope in pairs(value) do
        out.scopes[family] = vim.deepcopy(scope)
      end
    else
      out[key] = vim.deepcopy(value)
    end
  end
  return out
end

return M
