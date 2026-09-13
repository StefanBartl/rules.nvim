---@module 'rules.engine.waivers'
---@brief Load a repo's `.rules-waivers.json`: consciously accepted findings
--- that shouldn't re-flag on every run.
---@description
--- Format: `{ ["RULE-ID"] = "reason text", ... }`. A waiver never turns a
--- failing rule into a silent pass — it turns it into a distinct "waived"
--- status that still shows in the buffer report with its reason and is
--- excluded from the quickfix worklist, but stays visible. That is the
--- difference between waiving a finding and deleting the rule: the record
--- of "this was seen and consciously accepted" survives.

local M = {}

---@alias Rules.Waivers table<string, string>

--- Load `<root>/.rules-waivers.json`. A missing file means no waivers and
--- is not an error; an unparseable one is.
---@param root string
---@return Rules.Waivers waivers
---@return string|nil error
function M.load(root)
  local path = root .. "/.rules-waivers.json"
  if vim.fn.filereadable(path) == 0 then
    return {}, nil
  end

  local raw = table.concat(vim.fn.readfile(path), "\n")
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= "table" then
    return {}, path .. ": could not parse as JSON"
  end

  -- `{}` decodes ambiguously (empty object or empty list) -- only reject a
  -- genuinely non-empty list, e.g. `["DEP-01", "DEP-02"]`, a natural mistake
  -- for "these are waived" that would otherwise silently waive nothing.
  if next(decoded) ~= nil and vim.islist(decoded) then
    return {}, path .. ': must be a JSON object of {"RULE-ID": "reason"}, not a list'
  end

  for id, reason in pairs(decoded) do
    if type(id) ~= "string" or type(reason) ~= "string" then
      return {}, path .. ": every entry must be a string rule id mapped to a string reason"
    end
  end

  return decoded, nil
end

--- Waiver ids that don't match any loaded rule -- a rule that was renamed,
--- retired, or simply mistyped in `.rules-waivers.json` leaves an entry that
--- silently protects nothing, forever, with no indication it stopped
--- mattering. Pure data; see `health.lua` for where this surfaces.
---@param waivers Rules.Waivers
---@param rules Rules.ParsedRule[]
---@return string[] orphaned  waiver ids with no matching rule, sorted
function M.orphaned(waivers, rules)
  local known = {}
  for _, r in ipairs(rules) do
    known[r.id] = true
  end
  local orphaned = {}
  for id in pairs(waivers) do
    if not known[id] then
      orphaned[#orphaned + 1] = id
    end
  end
  table.sort(orphaned)
  return orphaned
end

return M
