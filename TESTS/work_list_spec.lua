-- TESTS/work_list_spec.lua -- the work list `rules-work-list/1` (docs/WORK-LIST.md): every rule of a run with its verdict,
-- its text and its waiver, the manual ones as `unchecked`; through the API, `:Rules check|gate --format=work-list`.
--
-- The fixture is a ruleset beside a project: automated rules that fail, pass, are waived (fully and for one path), a check
-- that cannot run, and a manual rule with a heading and prose. The clock is the `work_list.clock` seam.
---@diagnostic disable: need-check-nil
local rules = require("rules")
local config = require("rules.config")
local work_list = require("rules.report.work_list")

---@param path string
---@param lines string[]
local function write_lines(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
end

---@param path string
---@return string
local function real(path)
  return vim.fs.normalize(vim.uv.fs_realpath(path) or path)
end

---@param id string
---@param severity string
---@param heading string
---@param check string|nil
---@param prose string|nil
---@return string[]
local function rule(id, severity, heading, check, prose)
  local lines =
    { "#### `" .. id .. "` — " .. heading, "```rule", ('id = "%s",'):format(id), ('severity = "%s",'):format(severity) }
  if check then
    lines[#lines + 1] = "check = " .. check .. ","
  end
  lines[#lines + 1] = "```"
  if prose then
    lines[#lines + 1] = ""
    lines[#lines + 1] = prose
  end
  lines[#lines + 1] = ""
  return lines
end

---@return string ruleset, string project
local function fixture()
  local base = vim.fn.tempname()
  local ruleset, project = base .. "/ruleset", base .. "/project"
  local lines = { "# Work", "## 1. Code" }
  for _, part in ipairs({
    rule("WRK-01", "critical", "no FORBIDDEN", '{ type = "grep", pattern = "FORBIDDEN" }'),
    rule("WRK-02", "recommended", "no NOTHERE", '{ type = "grep", pattern = "NOTHERE" }'),
    rule("WRK-03", "recommended", "no LEGACY", '{ type = "grep", pattern = "LEGACY" }'),
    rule("WRK-04", "recommended", "errors carry context", nil, "Every error names the file it was about."),
    rule("WRK-05", "critical", "broken check", '{ type = "no-such-type" }'),
    rule("WRK-06", "recommended", "no PARTIAL", '{ type = "grep", pattern = "PARTIAL" }'),
  }) do
    vim.list_extend(lines, part)
  end
  write_lines(ruleset .. "/work.md", lines)
  write_lines(project .. "/code.lua", { "local a = 'FORBIDDEN'", "local b = 'LEGACY'", "local c = 'PARTIAL'" })
  write_lines(project .. "/vendor/lib.lua", { "local d = 'PARTIAL'" })
  write_lines(project .. "/.rules-waivers.json", {
    vim.json.encode({
      ["WRK-03"] = "kept on purpose",
      ["WRK-06"] = { reason = "vendored", paths = { "vendor/**" } },
    }),
  })
  config.setup({ rulesets = { ruleset }, gates = { work = { "WRK" } } })
  return ruleset, project
end

---@param doc table
---@return table<string, table>
local function by_id(doc)
  local out = {}
  for _, entry in ipairs(doc.entries) do
    out[entry.rule_id] = entry
  end
  return out
end

describe("rules-work-list/1", function()
  local saved_clock
  before_each(function()
    saved_clock = work_list.clock
    work_list.clock = function()
      return "2026-10-17T12:00:00Z"
    end
  end)
  after_each(function()
    work_list.clock = saved_clock
  end)

  it("has a head: schema, version, time, rulesets, target, scope", function()
    local ruleset, project = fixture()
    local json, code, doc, err = rules.check_family_work_list("WRK", project)
    assert.is_nil(err)
    assert.are.equal(1, code) -- WRK-01 is critical and fails
    assert.are.same(doc, vim.json.decode(json))
    assert.are.equal("rules-work-list", doc.schema)
    assert.are.equal(1, doc.schema_version)
    assert.are.equal("2026-10-17T12:00:00Z", doc.generated_at)
    assert.are.equal(1, #doc.rulesets)
    assert.are.equal(real(ruleset), real(doc.rulesets[1].source))
    assert.is_string(doc.rulesets[1].name)
    assert.are.equal(vim.fs.normalize(project), doc.target.path)
    assert.is_nil(doc.target.commit) -- not a git work tree
    assert.are.same({ kind = "family", family = "WRK" }, doc.scope)
    assert.are.equal(6, #doc.entries)
  end)

  it("gives every rule its verdict, its text and its places", function()
    local _, project = fixture()
    local _, _, doc = rules.check_family_work_list("WRK", project)
    local e = by_id(doc)

    assert.are.same({
      rule_id = "WRK-01",
      family = "WRK",
      severity = "critical",
      kind = "automated",
      status = "fail",
      ruleset = doc.rulesets[1].name,
      title = "`WRK-01` — no FORBIDDEN",
      section = "1. Code",
      description = "",
      source = e["WRK-01"].source,
      findings = { { file = "code.lua", line = 1, text = "local a = 'FORBIDDEN'" } },
    }, e["WRK-01"])
    assert.is_truthy(e["WRK-01"].source.file:find("work.md", 1, true))
    assert.is_number(e["WRK-01"].source.line)

    assert.are.equal("pass", e["WRK-02"].status)
    assert.are.same({}, e["WRK-02"].findings)
  end)

  it("lists a manual rule as unchecked work with its text, never as a pass", function()
    local _, project = fixture()
    local _, _, doc = rules.check_family_work_list("WRK", project)
    local manual = by_id(doc)["WRK-04"]
    assert.are.equal("manual", manual.kind)
    assert.are.equal("unchecked", manual.status)
    assert.are.equal("`WRK-04` — errors carry context", manual.title)
    assert.are.equal("Every error names the file it was about.", manual.description)
    assert.is_nil(manual.error)
  end)

  it("a check that cannot run is unchecked with its error, and no findings", function()
    local _, project = fixture()
    local _, _, doc = rules.check_family_work_list("WRK", project)
    local broken = by_id(doc)["WRK-05"]
    assert.are.equal("automated", broken.kind)
    assert.are.equal("unchecked", broken.status)
    assert.matches("unknown check type", broken.error)
    assert.are.same({}, broken.findings)
  end)

  it("carries the waiver: a full one makes the rule waived, one limited to paths keeps the rest as findings", function()
    local _, project = fixture()
    local _, _, doc = rules.check_family_work_list("WRK", project)
    local e = by_id(doc)
    assert.are.equal("waived", e["WRK-03"].status)
    assert.are.same({ reason = "kept on purpose" }, e["WRK-03"].waiver)

    assert.are.equal("fail", e["WRK-06"].status)
    assert.are.same({ reason = "vendored", paths = { "vendor/**" }, suppressed = 1 }, e["WRK-06"].waiver)
    assert.are.same({ { file = "code.lua", line = 3, text = "local c = 'PARTIAL'" } }, e["WRK-06"].findings)
  end)

  it("a gate gives the same entries and says which gate and families it ran", function()
    local _, project = fixture()
    local _, family_code, family_doc = rules.check_family_work_list("WRK", project)
    local json, code, doc, err = rules.run_gate_work_list("work", project)
    assert.is_nil(err)
    assert.are.equal(family_code, code)
    assert.are.same({ kind = "gate", gate = "work", families = { "WRK" } }, doc.scope)
    assert.are.same(family_doc.entries, doc.entries)
    assert.are.same(doc, vim.json.decode(json))
  end)

  it("names the commit of a target that is a git work tree", function()
    local _, project = fixture()
    local git = { "git", "-C", project, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false" }
    vim.fn.system({ "git", "-C", project, "init", "-q" })
    vim.fn.system(vim.list_extend(vim.deepcopy(git), { "add", "-A" }))
    vim.fn.system(vim.list_extend(vim.deepcopy(git), { "commit", "-q", "-m", "fixture" }))
    local head = vim.trim(vim.fn.system({ "git", "-C", project, "rev-parse", "HEAD" }))
    local _, _, doc = rules.check_family_work_list("WRK", project)
    assert.are.equal(head, doc.target.commit)
  end)

  it("errors like check_family_json: a broken waivers file is the error, no document", function()
    local _, project = fixture()
    write_lines(project .. "/.rules-waivers.json", { '{"WRK-01": {"reason": "r", "expires": "tomorrow"}}' })
    local json, code, doc, err = rules.check_family_work_list("WRK", project)
    assert.is_nil(json)
    assert.is_nil(code)
    assert.is_nil(doc)
    assert.matches("YYYY%-MM%-DD", err)
    local _, _, _, gerr = rules.run_gate_work_list("nope", project)
    assert.matches("unknown gate", gerr)
  end)

  it(":Rules check and :Rules gate print it with --format=work-list", function()
    local _, project = fixture()
    pcall(vim.api.nvim_del_user_command, "Rules")
    pcall(vim.api.nvim_del_user_command, "RulesVault")
    require("rules.bindings.usrcmds").setup()
    local printed = {}
    local saved_print = _G.print
    _G.print = function(text)
      printed[#printed + 1] = text
    end
    local ok, err = pcall(function()
      vim.cmd("Rules check " .. vim.fn.fnameescape(project) .. " --family=WRK --format=work-list")
      vim.cmd("Rules gate work " .. vim.fn.fnameescape(project) .. " --format=work-list")
    end)
    _G.print = saved_print
    pcall(vim.api.nvim_del_user_command, "Rules")
    pcall(vim.api.nvim_del_user_command, "RulesVault")
    assert.is_true(ok, err)
    assert.are.equal(2, #printed)
    local check_doc, gate_doc = vim.json.decode(printed[1]), vim.json.decode(printed[2])
    assert.are.equal("rules-work-list", check_doc.schema)
    assert.are.equal("family", check_doc.scope.kind)
    assert.are.equal("gate", gate_doc.scope.kind)
    assert.are.equal(6, #gate_doc.entries)
  end)
end)
