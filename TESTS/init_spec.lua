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
