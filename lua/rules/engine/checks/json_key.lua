---@module 'rules.engine.checks.json_key'
---@brief Check type "json_key_absent": a dotted key path must not be set in
--- a JSON file — the shape `.luarc.json`'s `workspace.library` needs
--- (`NEW-36`: the key *replaces* LuaLS's library injection rather than
--- adding to it, so its mere presence is the violation, not its value).

local M = {}

---@class Rules.Check.JsonKeyAbsent
---@field type "json_key_absent"
---@field path string  relative JSON file
---@field key string   dotted path, e.g. "workspace.library"

---@param spec Rules.Check.JsonKeyAbsent
---@param root string
---@return "pass"|"fail" status
---@return Rules.Finding[] findings
function M.run(spec, root)
  local full = root .. "/" .. spec.path
  if vim.fn.filereadable(full) == 0 then
    -- No file, nothing to violate.
    return "pass", {}
  end

  local raw = table.concat(vim.fn.readfile(full), "\n")
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= "table" then
    return "fail", { { file = full, line = 1, text = "could not parse as JSON: " .. tostring(decoded) } }
  end

  local node = decoded
  for segment in spec.key:gmatch("[^.]+") do
    if type(node) ~= "table" then
      node = nil
      break
    end
    node = node[segment]
  end

  if node ~= nil then
    return "fail", { { file = full, line = 1, text = spec.key .. " must not be set" } }
  end
  return "pass", {}
end

return M
