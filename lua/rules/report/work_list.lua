---@module 'rules.report.work_list'
---@brief The work list `rules-work-list/1`: one run's verdicts plus the manual rules with their text, for task tools.
---@description
--- A stable, versioned document a consumer (tasks.nvim) turns into tasks without reading a rule file: every rule of
--- the run is one entry with its verdict, its text (title, section, description), the places it found and its waiver.
--- A rule without a `check` (manual or agent) is an entry too, with `kind = "manual"` and `status = "unchecked"`: it
--- is work nobody has judged yet, never a pass. The schema is `docs/WORK-LIST.md`; a change that removes or renames a
--- field raises `SCHEMA_VERSION`, a new optional field does not.
---
--- Encoded with `lib.nvim.json.canonical`: sorted keys, no whitespace, the same bytes for the same run.
---
--- Not its job: running the checks (`rules.engine.runner`), the exit code (`rules.report.json.exit_code`, which the
--- work list shares), the catalog of all rules (`rules-export/1`, `rules.contract`).

local canonical = require("lib.nvim.json.canonical")
local runner = require("rules.engine.runner")
local waivers = require("rules.engine.waivers")

local M = {}

M.SCHEMA = "rules-work-list"
M.SCHEMA_VERSION = 1

---@class Rules.WorkList.Ruleset
---@field name string    the ruleset as it was named (`@vault/lua`, a folder name)
---@field source string  its folder or file
---@field origin? string where it was named ("call", "setup", "project", "vault")

---@class Rules.WorkList.Meta
---@field rulesets? Rules.Settings.Entry[]  the rulesets of the run (`Rules.Settings.entries`)
---@field target string                     the folder that was checked
---@field scope { kind: "family"|"gate", family?: string, gate?: string, families?: string[], diff?: string }

---@class Rules.WorkList.Waiver
---@field reason string
---@field expires? string    the last day it is valid
---@field paths? string[]    the paths it is limited to
---@field suppressed? integer partial: how many findings it held back (the rest stay `findings`)
---@field expired? boolean   it ran out and suppresses nothing

---@class Rules.WorkList.Entry
---@field rule_id string
---@field family string
---@field severity "critical"|"recommended"|"nice-to-have"
---@field kind "automated"|"manual"
---@field status "pass"|"fail"|"waived"|"unchecked"
---@field ruleset? string    the `name` of the ruleset the rule lives in
---@field title string       "" when the rule has no heading
---@field section? string    the heading above the rule
---@field description string the prose under the rule, "" when there is none
---@field source { file: string, line: integer }
---@field findings Rules.Finding[]  `file` relative to the target when it lies inside it
---@field error? string       an automated rule whose check could not run (status "unchecked")
---@field waiver? Rules.WorkList.Waiver

-- Seams for specs: read at call time.

---The time of the document, UTC, `YYYY-MM-DDTHH:MM:SSZ`.
---@return string
function M.clock()
  return os.date("!%Y-%m-%dT%H:%M:%SZ") --[[@as string]]
end

---The commit checked out in `dir`, nil when it is no git work tree.
---@param dir string
---@return string|nil
function M.commit_of(dir)
  local ok, hash = pcall(require("lib.nvim.git").head_hash, { dir = dir })
  if ok and type(hash) == "string" and hash:match("^%x+$") then
    return hash
  end
  return nil
end

---@param result Rules.Result
---@return Rules.WorkList.Waiver|nil
local function waiver_of(result)
  if result.status == "waived" then
    return { reason = result.waiver_reason, expires = result.waiver_expires, paths = result.waiver_paths }
  end
  local partial = result.partial_waiver
  if partial then
    return { reason = partial.reason, expires = partial.expires, paths = partial.paths, suppressed = partial.suppressed }
  end
  local expired = result.expired_waiver
  if expired then
    return { reason = expired.reason, expires = expired.expires, expired = true }
  end
  return nil
end

---@param result Rules.Result
---@return "pass"|"fail"|"waived"|"unchecked" status
---@return string|nil error
local function status_of(result)
  if result.status == "manual" then
    return "unchecked", nil
  end
  if result.status == "error" then
    local texts = {}
    for _, finding in ipairs(result.findings or {}) do
      texts[#texts + 1] = finding.text
    end
    return "unchecked", table.concat(texts, "; ")
  end
  return result.status, nil
end

---@param rulesets Rules.Settings.Entry[]
---@return fun(file: string): string|nil  the name of the ruleset that holds `file`
local function ruleset_finder(rulesets)
  local inside = {}
  for i, entry in ipairs(rulesets) do
    inside[i] = waivers.relativizer(entry.path)
  end
  return function(file)
    for i, entry in ipairs(rulesets) do
      if vim.fs.normalize(entry.path) == vim.fs.normalize(file) or inside[i](file) then
        return entry.name
      end
    end
    return nil
  end
end

--- The work list of one run, as a table.
---@param results Rules.Result[]
---@param meta Rules.WorkList.Meta
---@return table doc
function M.build(results, meta)
  local rulesets = meta.rulesets or {}
  -- absolute: `rule_id` plus `target.path` is the key a consumer finds its task by, "." would collide across projects
  local target = (vim.fs.normalize(vim.fn.fnamemodify(meta.target, ":p")):gsub("/+$", ""))
  local relative = waivers.relativizer(target)
  local ruleset_of = ruleset_finder(rulesets)

  local entries = {}
  for _, result in ipairs(results) do
    local rule = result.rule
    local status, err = status_of(result)
    local findings = {}
    if not err then
      for _, finding in ipairs(result.findings or {}) do
        findings[#findings + 1] = { file = relative(finding.file) or finding.file, line = finding.line, text = finding.text }
      end
    end
    entries[#entries + 1] = {
      rule_id = rule.id,
      family = runner.family_of(rule.id),
      severity = rule.severity,
      kind = rule.check ~= nil and "automated" or "manual",
      status = status,
      ruleset = rule.source_file and ruleset_of(rule.source_file) or nil,
      title = rule.title or "",
      section = rule.section,
      description = rule.text or "",
      source = { file = rule.source_file, line = rule.source_line },
      findings = canonical.array(findings),
      error = err,
      waiver = waiver_of(result),
    }
  end

  local list = {}
  for i, entry in ipairs(rulesets) do
    list[i] = { name = entry.name, source = entry.path, origin = entry.origin }
  end

  return {
    schema = M.SCHEMA,
    schema_version = M.SCHEMA_VERSION,
    generated_at = M.clock(),
    rulesets = canonical.array(list),
    target = { path = target, commit = M.commit_of(target) },
    scope = meta.scope,
    entries = canonical.array(entries),
  }
end

--- The work list of one run, as canonical JSON.
---@param results Rules.Result[]
---@param meta Rules.WorkList.Meta
---@return string
function M.encode(results, meta)
  return canonical.encode(M.build(results, meta))
end

return M
