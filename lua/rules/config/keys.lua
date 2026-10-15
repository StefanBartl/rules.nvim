---@module 'rules.config.keys'
---@brief The keys of a UI as `setup({ keys })` set them -- pure: a value to a list of keys, two actions on one key.
---@description
--- An action's value is a key (a string), a list of keys, or `false` (no key). The UI binds every key of the list; the help
--- text shows them. Two actions that end on the same key (`submit = "<Space>"` against the default `toggle`) cannot both
--- work, and which one wins is the order the buffer binds them in: `conflicts` finds them so `setup()` can say it.
---
--- Not its job: checking the shape of the option (`rules.config.schema`), binding (`rules.ui.form`).

local M = {}

---The keys of an action as a list.
---@param value string|string[]|false|nil
---@return string[]
function M.list(value)
  if type(value) == "string" then
    return { value }
  elseif type(value) == "table" then
    return value
  end
  return {}
end

---The keys of an action as text for a help line: `<Space>`, `<Space> / x`, `-` where the action has none.
---@param value string|string[]|false|nil
---@return string
function M.text(value)
  local keys = M.list(value)
  return #keys > 0 and table.concat(keys, " / ") or "-"
end

---The actions that share a key, in the order of `actions`.
---@param keymap table<string, string|string[]|false>  action -> key(s)
---@param actions string[]  the actions, in the order the UI binds them
---@return { key: string, actions: string[] }[] conflicts  `key` as the first action spells it
function M.conflicts(keymap, actions)
  local order, by_key = {}, {}
  for _, action in ipairs(actions) do
    local seen = {}
    for _, lhs in ipairs(M.list(keymap[action])) do
      -- `<C-s>` and `<C-S>` are one key
      local id = vim.keycode(lhs)
      if not seen[id] then
        seen[id] = true
        if not by_key[id] then
          by_key[id] = { key = lhs, actions = {} }
          order[#order + 1] = id
        end
        table.insert(by_key[id].actions, action)
      end
    end
  end
  local out = {}
  for _, id in ipairs(order) do
    if #by_key[id].actions > 1 then
      out[#out + 1] = by_key[id]
    end
  end
  return out
end

return M
