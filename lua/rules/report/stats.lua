---@module 'rules.report.stats'
---@brief Human-readable rendering of `rules.stats()` -- a catalog overview,
--- not a check run: no pass/fail, just how many rules exist per family and
--- how many of them are automated.

local M = {}

--- Render a `Rules.Stats` table as plain text lines.
---@param stats Rules.Stats
---@return string[] lines
function M.render(stats)
  local lines = { ("rules.nvim: %d rule(s) loaded"):format(stats.total), "" }

  local names = vim.tbl_keys(stats.families)
  table.sort(names)

  lines[#lines + 1] = ("%-8s %6s %8s %7s   %9s %12s %13s"):format(
    "family",
    "total",
    "checked",
    "manual",
    "critical",
    "recommended",
    "nice-to-have"
  )
  for _, family in ipairs(names) do
    local f = stats.families[family]
    lines[#lines + 1] = ("%-8s %6d %8d %7d   %9d %12d %13d"):format(
      family,
      f.total,
      f.checked,
      f.manual,
      f.severity.critical,
      f.severity.recommended,
      f.severity["nice-to-have"]
    )
  end

  return lines
end

--- Open the stats overview as a scratch buffer in a new tab -- same UX as
--- `report/buffer.lua`'s check/gate report.
---@param stats Rules.Stats
---@return nil
function M.open(stats)
  local lines = M.render(stats)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "rulesreport"
  vim.bo[buf].modifiable = false
  vim.cmd.tabnew()
  vim.api.nvim_win_set_buf(0, buf)
end

return M
