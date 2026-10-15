local rules = require("rules")
local config = require("rules.config")

---@return string
local function tmp_dir()
  local path = vim.fn.tempname()
  vim.fn.mkdir(path, "p")
  return path
end

---@param dir string
---@param name string
---@param lines string[]
local function write_file(dir, name, lines)
  vim.fn.writefile(lines, dir .. "/" .. name)
end

describe("rules.find_rule", function()
  it("returns the rule with a matching id", function()
    local dir = tmp_dir()
    write_file(dir, "a.md", {
      "```rule",
      'id = "DEP-01",',
      'severity = "recommended",',
      "```",
    })
    config.setup({ rulesets = { dir } })

    local rule = rules.find_rule("DEP-01")

    assert.is_not_nil(rule)
    assert.are.equal("recommended", rule.severity)
  end)

  it("returns nil for an id nothing loaded", function()
    config.setup({ rulesets = { tmp_dir() } })
    assert.is_nil(rules.find_rule("DEP-99"))
  end)
end)

describe("rules.check_family_json", function()
  it("ERR-11: warns when --family matches zero loaded rules, distinct from a clean empty run", function()
    -- Regression: a typo'd/transposed `--family=` used to produce an empty
    -- result list with no signal anywhere, visually identical to a family
    -- that genuinely has no findings.
    local dir = tmp_dir()
    write_file(dir, "a.md", { "```rule", 'id = "DEP-01",', 'severity = "recommended",', "```" })
    config.setup({ rulesets = { dir } })

    ---@diagnostic disable-next-line: duplicate-set-field
    local original_notify = vim.notify
    local messages = {}
    vim.notify = function(msg, _)
      messages[#messages + 1] = msg
    end

    local _, _, results = rules.check_family_json("SCE", dir)
    vim.notify = original_notify

    assert.are.equal(0, #results)
    assert.is_true(#messages > 0)
    assert.matches("SCE", messages[#messages])
  end)
end)

describe("waivers in a run", function()
  local waivers = require("rules.engine.waivers")

  ---@return string dir  a project with one critical rule that fails (a grep for a word the project has)
  local function failing_project()
    local dir = tmp_dir()
    write_file(dir, "a.md", {
      "```rule",
      'id = "SEC-01",',
      'severity = "critical",',
      'check = { type = "grep", pattern = "FORBIDDEN" },',
      "```",
    })
    write_file(dir, "code.lua", { "local x = 'FORBIDDEN'" })
    config.setup({ rulesets = { dir }, gates = { all = { "SEC" } } })
    return dir
  end

  local saved_clock
  before_each(function()
    saved_clock = waivers.clock
  end)
  after_each(function()
    waivers.clock = saved_clock
  end)

  it("a waivers file that exists and cannot be used is an error of the run, never 'no waivers'", function()
    local dir = failing_project()
    write_file(dir, ".rules-waivers.json", { '{"SEC-01": {"reason": "r", "expires": "tomorrow"}}' })

    local json, code, results, err = rules.check_family_json("SEC", dir)
    local gjson, gcode, gresults, gerr = rules.run_gate_json("all", dir)

    assert.is_nil(json)
    assert.is_nil(code)
    assert.is_nil(results)
    assert.matches("YYYY%-MM%-DD", err)
    assert.is_nil(gjson)
    assert.is_nil(gcode)
    assert.is_nil(gresults)
    assert.matches("YYYY%-MM%-DD", gerr)
  end)

  it("a waiver that is still valid waives the finding: the exit code is 0", function()
    local dir = failing_project()
    write_file(dir, ".rules-waivers.json", { '{"SEC-01": {"reason": "tracked", "expires": "2026-10-15"}}' })
    waivers.clock = function()
      return "2026-10-15"
    end

    local _, code, results = rules.check_family_json("SEC", dir)

    assert.are.equal(0, code)
    assert.are.equal("waived", results[1].status)
    assert.are.equal("2026-10-15", results[1].waiver_expires)
  end)

  it("the day after, the finding flags again, the exit code is 1 and the result says the waiver expired", function()
    local dir = failing_project()
    write_file(dir, ".rules-waivers.json", { '{"SEC-01": {"reason": "tracked", "expires": "2026-10-15"}}' })
    waivers.clock = function()
      return "2026-10-16"
    end

    local json, code, results = rules.check_family_json("SEC", dir)
    local entries = vim.json.decode(json)

    assert.are.equal(1, code)
    assert.are.equal("fail", results[1].status)
    assert.are.same({ reason = "tracked", expires = "2026-10-15" }, results[1].expired_waiver)
    assert.are.equal("2026-10-15", entries[1].expired_waiver.expires)
    assert.are.equal("tracked", entries[1].expired_waiver.reason)
  end)

  it("a gate judges the waivers the same way", function()
    local dir = failing_project()
    write_file(dir, ".rules-waivers.json", { '{"SEC-01": {"reason": "tracked", "expires": "2026-10-15"}}' })
    waivers.clock = function()
      return "2026-10-16"
    end

    local _, code, results = rules.run_gate_json("all", dir)

    assert.are.equal(1, code)
    assert.are.equal("2026-10-15", results[1].expired_waiver.expires)
  end)

  it("a run tells that waivers expired, whatever family it was for", function()
    local dir = failing_project()
    write_file(dir, ".rules-waivers.json", { '{"SEC-01": {"reason": "tracked", "expires": "2026-10-15"}}' })
    waivers.clock = function()
      return "2026-10-16"
    end
    local original_notify = vim.notify
    local messages = {}
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg)
      messages[#messages + 1] = msg
    end
    local original_open = require("rules.report.buffer").open
    require("rules.report.buffer").open = function() end

    rules.check_family("SEC", dir)
    require("rules.report.buffer").open = original_open
    vim.notify = original_notify

    local said = table.concat(messages, "\n")
    assert.matches("1 waiver%(s%)", said)
    assert.matches("SEC%-01 %(2026%-10%-15%)", said)
  end)
end)

describe("rules.stats", function()
  it("counts total rules, per-family checked/manual and severity", function()
    local dir = tmp_dir()
    write_file(dir, "a.md", {
      "```rule",
      'id = "DEP-01",',
      'severity = "recommended",',
      'check = { type = "grep", pattern = "x" },',
      "```",
      "```rule",
      'id = "DEP-02",',
      'severity = "critical",',
      "```",
      "```rule",
      'id = "SEC-01",',
      'severity = "nice-to-have",',
      "```",
    })
    config.setup({ rulesets = { dir } })

    local stats = rules.stats()

    assert.are.equal(3, stats.total)
    assert.are.equal(2, stats.families.DEP.total)
    assert.are.equal(1, stats.families.DEP.checked)
    assert.are.equal(1, stats.families.DEP.manual)
    assert.are.equal(1, stats.families.DEP.severity.recommended)
    assert.are.equal(1, stats.families.DEP.severity.critical)
    assert.are.equal(1, stats.families.SEC.total)
    assert.are.equal(0, stats.families.SEC.checked)
    assert.are.equal(1, stats.families.SEC.severity["nice-to-have"])
  end)

  it("returns zero total and no families for an empty ruleset", function()
    config.setup({ rulesets = { tmp_dir() } })
    local stats = rules.stats()
    assert.are.equal(0, stats.total)
    assert.are.same({}, stats.families)
  end)
end)
