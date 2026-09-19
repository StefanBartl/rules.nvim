---@module 'rules.engine.checks.json_key'
---@brief Check type "json_key_absent": a dotted key path must not be set in
--- a JSON file — the shape `.luarc.json`'s `workspace.library` needs
--- (`NEW-36`: the key *replaces* LuaLS's library injection rather than
--- adding to it, so its mere presence is the violation, not its value).

-- ERR-05/06: `lib.lua.error.safe_call` instead of a hand-rolled `pcall`.
local safe_error = require("lib.lua.error")
local errline = require("rules.engine.checks.errline")

local M = {}

---@class Rules.Check.JsonKeyAbsent
---@field type "json_key_absent"
---@field path string  relative JSON file
---@field key string   dotted path, e.g. "workspace.library"

---@param spec Rules.Check.JsonKeyAbsent
---@param root string
---@return "pass"|"fail"|"error" status
---@return Rules.Finding[] findings
function M.run(spec, root)
  -- PRIN-25: `spec` is a raw table from a user-authored Markdown file --
  -- validate before `root .. "/" .. spec.path` and `spec.key:gmatch(...)`
  -- below, matching lua_predicate.lua's own guarded pattern.
  if type(spec.path) ~= "string" or type(spec.key) ~= "string" then
    return "error", { { file = root, line = 1, text = "json_key_absent check needs a string `path` and `key`" } }
  end

  local full = root .. "/" .. spec.path
  if vim.fn.filereadable(full) == 0 then
    -- No file, nothing to violate.
    return "pass", {}
  end

  -- ERR-01: `filereadable` above only checks openability at that instant --
  -- a TOCTOU window (removed/renamed/locked before this read) means
  -- `readfile` can still throw rather than return an error value.
  local read_ok, lines = safe_error.safe_call(vim.fn.readfile, full)
  if not read_ok then
    -- `lines.message` is a full multi-line `debug.traceback()` string --
    -- embedding it as-is would crash `report/buffer.lua`'s render instead
    -- of showing this friendly error (see errline.lua).
    return "error", { { file = full, line = 1, text = "could not read file: " .. errline.first_line(lines.message) } }
  end

  local raw = table.concat(lines, "\n")
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
