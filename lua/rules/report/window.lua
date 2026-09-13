---@module 'rules.report.window'
---@brief Shared "find or create" logic for rules.nvim's report windows.
---@description
--- UI-31/51/52: a repeated `:Rules check`/`gate`/`stats` used to pile up a
--- fresh tab every time, with no way to find a previous report again and
--- nothing to close the orphaned ones. This finds a still-open report
--- window (tagged via `vim.w`, not a module-global registry -- a stale
--- registry entry is a recurring, concrete bug source per UI-31) and
--- replaces its content in place; only opens a new tab when no tagged
--- window is still showing a report buffer.

local TAG = "rules_nvim_report"

local M = {}

---@return integer|nil win  a window still tagged and still showing a report
local function find_reusable_window()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.w[win][TAG] then
      local buf = vim.api.nvim_win_get_buf(win)
      -- The user may have navigated that window to something else since --
      -- a stale tag on a now-unrelated buffer must not hijack it.
      if vim.bo[buf].filetype == "rulesreport" then
        return win
      end
    end
  end
  return nil
end

--- Render `lines` into the tagged report window, reusing it (any tab) if
--- one is still open and still showing a report; opens a fresh tab
--- otherwise.
---@param lines string[]
---@return nil
function M.open(lines)
  local win = find_reusable_window()
  local buf

  if win then
    vim.api.nvim_set_current_win(win)
    buf = vim.api.nvim_win_get_buf(win)
    vim.bo[buf].modifiable = true
  else
    buf = vim.api.nvim_create_buf(false, true)
    vim.cmd.tabnew()
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.w[win][TAG] = true
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "rulesreport"
  vim.bo[buf].modifiable = false
end

return M
