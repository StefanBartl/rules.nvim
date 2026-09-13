---@module 'rules.report.json'
---@brief Machine-readable report for headless/CI use.
---@description
--- `M.exit_code` only trips on a "critical" severity rule that actually
--- failed or errored — matching the severity semantics the buffer/quickfix
--- reports already use elsewhere. A "manual" rule (no `check` field) never
--- affects the exit code: it has no automated verdict, and treating "nobody
--- ran a check" as a CI failure would be exactly the fake-verdict shortcut
--- this plugin exists to avoid.

local M = {}

---@class Rules.Report.JsonEntry
---@field id string
---@field severity "critical"|"recommended"|"nice-to-have"
---@field status "pass"|"fail"|"error"|"manual"|"waived"
---@field findings Rules.Finding[]
---@field waiver_reason? string  set only when status is "waived" -- LLS-15,
--- same reasoning as `Rules.Result.waiver_reason`: the key is genuinely
--- absent otherwise, not present with a `nil` value

--- Turn a run's results into a plain array of JSON-encodable entries.
---@param results Rules.Result[]
---@return Rules.Report.JsonEntry[]
function M.to_entries(results)
  local entries = {}
  for _, res in ipairs(results) do
    entries[#entries + 1] = {
      id = res.rule.id,
      severity = res.rule.severity,
      status = res.status,
      findings = res.findings,
      waiver_reason = res.waiver_reason,
    }
  end
  return entries
end

--- Encode a run's results as a JSON string.
---@param results Rules.Result[]
---@return string
function M.encode(results)
  return vim.json.encode(M.to_entries(results))
end

--- The exit code a headless/CI run should use: 1 if any "critical" rule
--- failed or errored, 0 otherwise. A "waived" rule never counts here either
--- — that is the entire point of a waiver.
---@param results Rules.Result[]
---@return 0|1
function M.exit_code(results)
  for _, res in ipairs(results) do
    if res.rule.severity == "critical" and (res.status == "fail" or res.status == "error") then
      return 1
    end
  end
  return 0
end

return M
