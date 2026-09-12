---@module 'rules.report.quickfix'
---@brief Push a run's findings into the quickfix list.
---@description
--- `UI-36` (from the rule catalog this plugin is built to check): hit lists
--- belong in the quickfix list too, not only in a plugin-private UI.

local M = {}

--- Replace the quickfix list with this run's findings.
---@param results Rules.Result[]
---@return nil
function M.set(results)
  local items = {}
  for _, res in ipairs(results) do
    if res.status == "fail" or res.status == "error" then
      for _, f in ipairs(res.findings) do
        items[#items + 1] = {
          filename = f.file,
          lnum = f.line,
          text = ("[%s] %s"):format(res.rule.id, f.text),
        }
      end
    end
  end
  vim.fn.setqflist({}, " ", { title = "rules.nvim", items = items })
end

return M
