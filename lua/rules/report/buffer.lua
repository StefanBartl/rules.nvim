---@module 'rules.report.buffer'
---@brief Human-readable report: one line per checked rule, plus a worklist
--- section for rules with no automated check.
---@description
--- A "manual" rule never gets a pass/fail line here — that would be exactly
--- the fake verdict this plugin's whole concept exists to avoid. It gets a
--- worklist entry instead, pointing back at its source file and line.

local window = require("rules.report.window")

local M = {}

---@type table<string, string>
local ICON = { critical = "🔴", recommended = "🟡", ["nice-to-have"] = "🟢" }

--- Render a run's results as plain text lines.
---@param results Rules.Result[]
---@return string[] lines
function M.render(results)
  local lines = { "rules.nvim report", "" }
  local manual = {}

  for _, res in ipairs(results) do
    local icon = ICON[res.rule.severity] or "?"
    if res.status == "manual" then
      manual[#manual + 1] = res
    elseif res.status == "pass" then
      lines[#lines + 1] = ("%s %s -- ok"):format(icon, res.rule.id)
    elseif res.status == "waived" then
      local scope = ""
      if res.waiver_expires then
        scope = scope .. (", until %s"):format(res.waiver_expires)
      end
      if res.waiver_paths then
        scope = scope .. (", only in %s"):format(table.concat(res.waiver_paths, ", "))
      end
      lines[#lines + 1] = ("⚪ %s -- waived (%s%s): %d finding(s) suppressed"):format(
        res.rule.id,
        res.waiver_reason,
        scope,
        #res.findings
      )
    elseif res.status == "error" then
      local msg = res.findings[1] and res.findings[1].text or "?"
      lines[#lines + 1] = ("%s %s -- check errored (%s)"):format(icon, res.rule.id, msg)
    else
      lines[#lines + 1] = ("%s %s -- %d finding(s)"):format(icon, res.rule.id, #res.findings)
      for _, f in ipairs(res.findings) do
        lines[#lines + 1] = ("      %s:%d: %s"):format(f.file, f.line, f.text)
      end
    end
    local partial = res.partial_waiver
    if partial then
      lines[#lines + 1] = ("      %d more finding(s) waived in %s (%s)"):format(
        partial.suppressed,
        table.concat(partial.paths, ", "),
        partial.reason
      )
    end
    local expired = res.expired_waiver
    if expired then
      lines[#lines + 1] = ("      waiver expired on %s (%s): renew it or remove it"):format(expired.expires, expired.reason)
    end
  end

  if #manual > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "-- no automated check, review by hand --"
    for _, res in ipairs(manual) do
      local icon = ICON[res.rule.severity] or "?"
      lines[#lines + 1] = ("%s %s (%s:%d)"):format(icon, res.rule.id, res.rule.source_file, res.rule.source_line)
    end
  end

  return lines
end

--- Open the report as a scratch buffer -- reuses a still-open report
--- window if one exists (see `rules.report.window`), opens a new tab
--- otherwise.
---@param results Rules.Result[]
---@return nil
function M.open(results)
  window.open(M.render(results))
end

return M
